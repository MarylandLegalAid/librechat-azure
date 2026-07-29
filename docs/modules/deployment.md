# How deploys work

One script deploys this stack. Everything else is a way of asking it to run.

```
scripts/deploy.sh
```

Two things trigger it, and they run identical code. That is the point: a mechanism
only one party uses is a mechanism only one party finds the bugs in.

| Trigger | Who | What it does |
|---|---|---|
| **systemd timer** | Grantees, by default | Every five minutes, checks for new commits. Almost always exits immediately. |
| **GitHub Actions** | Maryland Legal Aid | On push to `main`, runs the same script with `--force`. |

## What deploy.sh does

1. Takes a lock, so two runs cannot overlap. A second run exits quietly.
2. Records the current commit, for rollback.
3. Fast-forwards to `origin/main`. **If nothing changed and `--force` was not given,
   it stops here** — which is what makes a five-minute timer nearly free.
4. Rebuilds `.env` from Azure Key Vault.
5. Merges `librechat.yaml` with the storage overlay into `librechat.runtime.yaml`.
6. Pulls images.
7. Starts containers.
8. Polls `/health` for up to two minutes.
9. **If that fails**: rolls back to the previous commit, starts it again, and exits
   non-zero.

Step 8 matters more than it looks. A container being "running" is not the same as the
application working — a crash-looping container and one stuck on bad configuration
both report as up to Docker. Asking the application whether it is working is the only
check that means anything.

## The checkout is a mirror, not a workspace

`deploy.sh` uses `git reset --hard`, not `git pull`. Anything edited by hand on the
machine is discarded at the next deploy.

This is deliberate. The repository is the only source of truth for configuration, and
there is nowhere else to look when something is wrong. The cost is that you cannot
hotfix on the box; the benefit is that "what is running" is always answerable by
reading a commit.

## Why the timer needs no configuration

The repository is **public**, so `git pull` needs no credentials at all. There is no
deploy key, no token, no service account, nothing to rotate and nothing to leak.

That is the entire configuration burden of autodeploy for a grantee: none.

## Rollback

Automatic, on a failed health check. The machine goes back to the previous commit and
starts it.

Note what happens next: the bad commit is still on `origin/main`, so the next timer
run tries it again and fails again. That is intentional — a machine that quietly
stopped deploying would be worse. Fix it or revert it on the branch.

If the rollback also fails, the script says so in the loudest terms it has and stops.
At that point the site is down and it needs a person.

## Changing a secret does not deploy anything

The timer watches git, not your key vault. After changing a secret:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "/srv/librechat/app/scripts/deploy.sh --force" \
  --query "value[0].message" -o tsv
```

## Watching a deploy

```bash
# from the machine
journalctl -u librechat-deploy.service -f

# when did it last run, and when will it run again
systemctl list-timers librechat-deploy.timer
```

## GitHub Actions deploys

Maryland Legal Aid deploys through a pipeline instead of the timer, for gating and an
audit trail. If you want the same:

### 1. An app registration with a federated credential

No client secret exists. GitHub mints a short-lived token asserting "this is a run of
this workflow, on this branch, in this repository", and Azure trusts that assertion.

```bash
APP_ID=$(az ad app create --display-name "librechat-deploy" --query appId -o tsv)
az ad sp create --id "$APP_ID"

az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:YOURORG/librechat-azure:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

### 2. Permission on the VM, and only the VM

```bash
VM_ID=$(az vm show -g rg-librechat-prod -n vm-librechat-prod --query id -o tsv)
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

az role assignment create \
  --role "Virtual Machine Contributor" \
  --assignee-object-id "$SP_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$VM_ID"
```

Scoped to the machine, not the resource group and not the subscription. That role
permits running a command on that one machine and nothing else.

### 3. Repository variables

Settings → Secrets and variables → Actions → **Variables** (not Secrets — none of
these is one):

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | the app registration's application ID |
| `AZURE_TENANT_ID` | your tenant ID |
| `AZURE_SUBSCRIPTION_ID` | your subscription ID |
| `AZURE_RESOURCE_GROUP` | `rg-librechat-prod` |
| `AZURE_VM_NAME` | `vm-librechat-prod` |

The workflow skips itself entirely when `AZURE_CLIENT_ID` is unset, so forks do not
get a red tick on their first push.

### 4. Turn the timer off

Otherwise a timer run can race a pipeline run. They will not corrupt anything — the
lock prevents that — but two things deploying is confusing to reason about.

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

az keyvault secret set --vault-name "$VAULT" \
  --name DEPLOY-TIMER-ENABLED --value "false" --output none

az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "systemctl disable --now librechat-deploy.timer"
```

!!! warning "`az vm run-command` reports success too eagerly"
    It exits zero as long as it managed to run *something*. The script's own exit
    status is buried in the output rather than reflected in the CLI's.

    `.github/workflows/deploy.yml` parses the output for the success line rather than
    trusting the exit code. If you write your own automation around `run-command`,
    do the same — otherwise a failed deploy shows a green tick, which is worse than
    having no pipeline at all.
