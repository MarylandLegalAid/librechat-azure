# How deploys work

One script deploys this stack. Everything else is a way of asking it to run.

```
scripts/deploy.sh
```

Two things *can* trigger it, and they run identical code — deliberately, because a
mechanism only one party uses is a mechanism only one party finds the bugs in.

| Trigger | Who | What it does |
|---|---|---|
| **systemd timer** | Everyone, Maryland Legal Aid included | Every five minutes, checks for new commits. Almost always exits immediately. |
| **GitHub Actions** | Nobody yet — ships unconfigured | On push to `main`, *would* run the same script with `--force`. Skips itself while `AZURE_CLIENT_ID` is unset. |

!!! note "The pipeline has never actually run"
    `deploy.yml` is gated on `if: vars.AZURE_CLIENT_ID != ''`, and that variable is not
    set on this repository. Every run of that workflow so far — 33 of them at the time of
    writing — has been skipped, including Maryland Legal Aid's. **Production deploys here
    come from the timer, and only from the timer.**

    This is worth saying plainly rather than leaving the table to imply otherwise, because
    the sentence above it claims the two paths keep each other honest. Right now one of
    them is exercised by nobody, so treat [GitHub Actions deploys](#github-actions-deploys)
    as an untested setup path rather than a second working mechanism.

    The practical consequence: **a push does not deploy immediately.** It deploys within
    five minutes, when the timer next looks. If you need it now, run `scripts/deploy.sh
    --force` on the host.

## Infrastructure is a separate deploy, and it is not automated

Everything on this page deploys the **application** — containers, configuration, `.env`.
It never touches the VM, the disk, the network security group, or the alerts. Those come
from the Bicep template in `infra/`, and nothing applies it automatically:

```bash
az deployment group create \
  --resource-group rg-librechat-prod \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json
```

The GitHub Actions deploy cannot do this even if you wanted it to — its app registration
holds **Virtual Machine Contributor on the VM alone**, which permits running a command on
that one machine and nothing else. `validate.yml` builds and lints the template on every
pull request but never deploys it. So infrastructure changes only when a person runs the
command above.

That matters because of what it implies for changes made by hand:

!!! warning "A change made directly in Azure is reverted by the next template deploy"
    The template is the source of truth for everything it declares. If you edit an NSG
    rule, an alert, or a disk setting in the portal or with `az`, that change survives
    only until someone runs `az deployment group create` — which then quietly restores
    whatever `infra/main.parameters.json` says.

    **Change it in both places, at the moment you change it.** The one that has already
    caused trouble here is the SSH allow list: fixing a lockout live and not mirroring it
    into the parameters file gives you a fix that expires without warning, during someone
    else's deploy. See
    [Locked out of SSH](../troubleshooting.md#locked-out-of-ssh).

`infra/main.parameters.json` is **gitignored** on purpose — it carries your machine name,
your admin source addresses, and your alert recipients, none of which belong in a public
repository. `infra/main.parameters.example.json` is the committed shape to copy.

The consequence is that the filled-in file is not shared and not versioned. A copy on a
second machine drifts silently, and deploying from there applies *its* values. If more
than one person can run a template deploy, agree on which machine is authoritative, and
compare the file against live state before deploying:

```bash
jq -r '.parameters.adminSourceAddressPrefixes.value[]' infra/main.parameters.json
az network nsg rule show -g rg-librechat-prod --nsg-name nsg-librechat-prod \
  --name allow-ssh-admin --query "[sourceAddressPrefix, sourceAddressPrefixes]" -o json
```

A missing parameters file fails loudly rather than dangerously: `adminSshPublicKey`,
`adminSourceAddressPrefixes` and `alertEmail` are declared without defaults, so a deploy
without them stops instead of provisioning an SSH rule that allows everyone or no one.
A **stale** file is the dangerous case, because it deploys cleanly.

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

The intent was for Maryland Legal Aid to deploy through a pipeline instead of the timer,
for gating and an audit trail. **That was never finished** — the variables below are
unset, so the workflow skips itself and MLA runs on the timer like everyone else. The
steps are written and the workflow is committed, but neither has been exercised
end to end. If you want to set it up, expect to debug it rather than to follow it:

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

!!! danger "Only after you have watched the pipeline deploy successfully"
    The workflow skips itself silently when its variables are missing or wrong. Turning
    the timer off before a green, genuinely-executed pipeline run leaves the deployment
    with **no** trigger at all: pushes land on `main`, nothing applies them, and the
    running stack quietly falls behind the repository with nothing reporting a failure.

    Confirm the run actually executed rather than skipped — `gh run list --workflow=deploy.yml`
    should show `success`, not `skipped` — and only then disable the timer.

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

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
