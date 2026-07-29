# When it breaks

The failures we have actually hit, with what caused them. Roughly in the order you are
likely to meet them.

## Start here

```bash
# is the application answering
curl -fsS https://chat.yourorg.org/api/health

# what is running
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "docker compose -f /srv/librechat/app/compose.yaml ps" \
  --query "value[0].message" -o tsv

# what the last deploy did
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "journalctl -u librechat-deploy.service -n 80 --no-pager" \
  --query "value[0].message" -o tsv

# what the application is saying
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "docker compose -f /srv/librechat/app/compose.yaml logs --tail 100 api" \
  --query "value[0].message" -o tsv
```

`deploy.sh` logs what it did at every stage and says loudly when it rolls back. Read
that before anything else.

---

## Locked out of SSH

Your public address changed and the firewall no longer recognizes it. SSH is refused
at the network, before it reaches the machine, so no key or certificate helps.

**This needs no SSH to fix, and takes about a minute.**

### In the portal

1. Azure Portal → resource group `rg-librechat-prod` → `nsg-librechat-prod`
2. **Inbound security rules** → `allow-ssh-admin`
3. **Source IP addresses/CIDR ranges** → replace with your current address, `/32`
4. **Save**

### From a command line, if you have one signed in

```bash
MY_IP=$(curl -fsS https://api.ipify.org)
az network nsg rule update \
  --resource-group rg-librechat-prod \
  --nsg-name nsg-librechat-prod \
  --name allow-ssh-admin \
  --source-address-prefixes "$MY_IP/32"
```

!!! tip "You may not need SSH at all"
    `az vm run-command` goes through the Azure control plane, not the network, and
    keeps working when SSH does not. Most operational tasks can be done that way —
    see [SSH with Entra ID](modules/entra-ssh.md#doing-things-without-ssh-at-all).

## `Permission denied (publickey)` and you know you have access

Your Entra SSH certificate expired. The message says nothing about expiry, which has
cost real time in real investigations.

```bash
az ssh config --file ~/.ssh/config -g rg-librechat-prod -n vm-librechat-prod
```

Or just run `az ssh vm` again. **Do this before investigating anything else.**

---

## Redeploying the template fails with `PropertyChangeNotAllowed`

```
Changing property 'osProfile.customData' is not allowed.
```

**Azure will not let you change a virtual machine's cloud-init content after the
machine exists.** Not "it is ignored" — the deployment fails outright.

The template substitutes a handful of values into `infra/cloud-init.yaml`, so changing
any of these parameters and redeploying hits this:

- `namePrefix` or `environment` — they determine the key vault's name
- `repoUrl`, `repoBranch`
- `dataDir`
- `enableDeployTimer`

Everything else — `vmSize`, `healthCheckUrl`, `adminSourceAddressPrefixes`, alert
settings, disk size — redeploys cleanly.

### If the machine is new and holds nothing

Delete the VM and let the template recreate it. The data disk is a **separate
resource** with `deleteOption: Detach`, so it survives and is reattached:

```bash
az vm delete -g rg-librechat-prod -n vm-librechat-prod --yes
az deployment group create -g rg-librechat-prod \
  --template-file infra/main.bicep --parameters @infra/main.parameters.json
```

### If the machine is in production

Do not delete it. Change the setting on the machine instead — cloud-init only ever
wrote these to a file, and that file is editable:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "sed -i 's|^REPO_URL=.*|REPO_URL=https://github.com/YOURORG/librechat-azure.git|' /etc/librechat-deploy.conf && cat /etc/librechat-deploy.conf" \
  --query "value[0].message" -o tsv
```

Then bring the template's parameter back in line with reality so the two do not
disagree, and accept that this particular parameter is now advisory for this machine.

## The machine never finished setting itself up

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "cloud-init status --long; tail -50 /var/log/cloud-init-output.log" \
  --query "value[0].message" -o tsv
```

Common causes: a transient network failure fetching Docker's repository, or the data
disk not appearing. Both are usually fixed by rerunning the failed part by hand — the
output names it.

## The site does not load at all

In order:

1. **Does DNS resolve to this machine?** `dig +short chat.yourorg.org`
2. **Is the stack up?** `docker compose ps` as above.
3. **Is Caddy failing to get a certificate?**

    ```bash
    docker compose -f /srv/librechat/app/compose.yaml logs caddy --tail 50
    ```

    Almost always DNS not resolving to this machine yet, or port 80 blocked. Caddy
    needs port 80 for the ACME challenge; it is the only reason it is open.

## Certificate warning in the browser

The hostname is not resolving to this machine, so no certificate was ever issued. Fix
DNS, wait for propagation, then reload — Caddy issues on the first request.

If you have been retrying for a while, you may have hit Let's Encrypt's rate limit for
that name. Wait an hour.

---

## I cannot send a message

### The model list is empty

`ANTHROPIC_MODELS` / `OPENAI_MODELS` are unset or the API key is missing.

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "grep -c . /srv/librechat/app/.env; grep -o '^[A-Z_]*' /srv/librechat/app/.env | sort | head -40" \
  --query "value[0].message" -o tsv
```

That prints variable **names** only, never values. If a name you expect is missing,
the usual cause is a Key Vault secret named with an underscore where it needs a dash,
or a typo. See [Add your secrets](quickstart/02-secrets.md#the-one-thing-that-trips-everyone-up).

### A message returns an error immediately

Usually the API key is wrong, out of credit, or the model identifier does not exist in
your account. `docker compose logs api --tail 50` names which.

### It works, but fails as soon as a tool is used

This is the GPT-5.6 Responses API problem. A plain "hello" passes while the
configuration is broken.

Read **[GPT-5.6 and the Responses API](modules/models-gpt56-responses.md)**.

Check first:

```bash
grep '^OPENAI_MODELS=' env.defaults      # must NOT contain a gpt-5.6 model
yq '.modelSpecs.addedEndpoints' librechat.yaml   # must NOT contain openAI
```

### An agent fails but ordinary chat works

Its `provider` does not match an endpoint name byte for byte.

```bash
docker compose exec mongodb mongosh LibreChat --quiet --eval '
  db.agents.aggregate([
    { $group: { _id: { model: "$model", provider: "$provider" }, n: { $sum: 1 } } }
  ]).forEach(printjson)'
```

Compare against `endpoints.custom[].name` in `librechat.yaml`. `scripts/validate-config.sh`
checks this for the committed mapping table, but an agent edited by hand can still
drift.

---

## MCP tools do not appear

### `Domain ... is not allowed` in the logs

The SSRF allow list. LibreChat blocks internal hostnames for MCP URLs by default, and
a Compose service name is an internal hostname.

Every `mcpServers` URL needs a matching `mcpSettings.allowedAddresses` entry, as
`host:port` with no scheme. See
[Custom tools (MCP)](modules/mcp-servers.md#the-ssrf-allow-list).

### The container is not running

Check `COMPOSE_PROFILES` includes the profile:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

az keyvault secret show --vault-name "$VAULT" --name COMPOSE-PROFILES --query value -o tsv
```

### It is running but unhealthy

```bash
docker compose exec api curl -fsS http://legalserver-mcp:3001/healthz
```

For LetterWriter, the usual cause is a `.docx` named in `letterheads.json` that is not
in `/srv/librechat/data/letterheads`. It refuses to start and names the file.

---

## Search returns nothing

Meilisearch rebuilds its index from MongoDB, which takes a few minutes after a restore
or a version change. Wait, then retry.

If it never recovers:

```bash
docker compose logs meilisearch --tail 50
```

A version mismatch on the data directory looks like a crash loop. The version is part
of the path (`meili_data_v1.35.1`) precisely so this cannot happen silently — see
[Upgrading](modules/upgrading.md).

## File chat returns nonsense

If it started after a configuration change, check `EMBEDDINGS_MODEL`. Changing it
invalidates every vector already stored, and file chat does not error — it returns
confident nonsense — until every document is re-uploaded.

Change it back. If it has genuinely been changed and documents re-embedded, that is
the state you are in and there is no shortcut.

## Old attachments will not open

If you migrated from S3 and left `FILE_STORAGE=disk`, those records are still served
from the bucket. Check the AWS credentials are still set and the bucket still exists.

See [S3 and legacy file storage](modules/storage-s3-legacy.md).

---

## A deploy failed

`deploy.sh` rolls back automatically and says so. The site should be up on the previous
commit.

The bad commit is still on `main`, so the next timer run tries it again and fails
again. That is intentional — a machine that quietly stopped deploying would be worse.
Fix it or revert it.

### `ROLLBACK ALSO FAILED`

The site is down. In order:

```bash
docker compose -f /srv/librechat/app/compose.yaml ps
docker compose -f /srv/librechat/app/compose.yaml logs --tail 200 api
```

Then check the two things that stop the stack starting at all:

```bash
mountpoint /srv/librechat/data          # the data disk
ls -la /srv/librechat/app/.env          # should exist, mode 0600
```

### `is not a mounted filesystem`

`deploy.sh` refuses to start when the data disk is not mounted, because the stack would
otherwise come up empty and write to the OS disk.

```bash
lsblk
cat /etc/fstab
mount -a
```

### `no enabled secrets` from render-env.sh

Either the vault has not been seeded, or the machine's managed identity lost its role
assignment.

```bash
PRINCIPAL=$(az vm show -g rg-librechat-prod -n vm-librechat-prod --query identity.principalId -o tsv)
az role assignment list --assignee "$PRINCIPAL" --output table
```

It needs **Key Vault Secrets User** on the vault.

---

## The disk filled up

```bash
df -h /srv/librechat/data
du -sh /srv/librechat/data/* | sort -h
```

Usual culprits: local backup staging that failed to clean up, and Docker images from
past versions.

```bash
docker image prune -a --filter "until=168h"
```

Growing the data disk is a portal operation and does not need a rebuild.

## Everything is slow

Check the alert emails first — CPU and memory alerts fire before it becomes obvious to
users.

```bash
docker stats --no-stream
```

If MongoDB is consistently busy, the data disk's IOPS limit is the likely constraint.
Resizing to a larger Premium SSD raises it. If the application is CPU-bound, resize the
VM — the data disk is a separate resource and comes with you.

---

## Still stuck

Open an issue with:

- what you expected and what happened
- the full `deploy.sh` output
- `docker compose ps`
- the image tag (`docker compose images api`)
- whether you have modified `librechat.yaml`

**Never paste a `.env` file, a log containing an API key, or a key vault value.** If
you think you may have exposed a secret, rotate it first and mention that you have.

See [SUPPORT.md](https://github.com/MarylandLegalAid/librechat-azure/blob/main/SUPPORT.md).
