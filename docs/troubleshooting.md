# When it breaks

The failures we have actually hit, with what caused them. Roughly in the order you are
likely to meet them.

## Start here

```bash
# is the application answering
curl -fsS https://chat.yourorg.org/health

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

### If a *feature* is broken rather than the whole application

```bash
./scripts/check-secrets.sh --vault "$VAULT"
```

Read-only, prints no secret values, and answers the question the health check cannot:
**is the configuration complete?** Every one of these variables is optional as far as
LibreChat is concerned — it starts, reports itself healthy, and fails only when somebody
uses the thing.

It checks by feature. A feature is switched on by a trigger variable, and once it is on
its companions stop being optional, which is how "not configured" is told apart from
"half configured". It also catches the shapes that are set but wrong: a `CREDS_KEY` of
the wrong length, a `DOMAIN_SERVER` with a trailing slash, an `OPENID_CALLBACK_URL` given
as a full URL when a path is required, and any of the all-or-nothing groups where setting
some of the variables and not the rest is ignored entirely and in silence.

On the machine itself, check what the application actually received:

```bash
./scripts/check-secrets.sh --env-file /srv/librechat/app/.env
```

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
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

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

### If it followed a database restore, waiting will not fix it

**A restored database tells LibreChat the index is already built, and it believes it.**

`indexSync` never asks Meilisearch how many documents it holds. It reads a `_meiliIndex`
flag on the MongoDB documents — and a dump restored from another machine carries that
flag set `true`, because those documents genuinely were indexed, in the *other*
machine's Meilisearch. Your index is empty, the flags say otherwise, the sync is
skipped, and nothing anywhere reports a problem.

Ask Meilisearch directly rather than trusting the application:

```bash
docker compose exec -T meilisearch \
  curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://127.0.0.1:7700/stats
```

If `convos` and `messages` are far below the MongoDB counts, clear the flags and restart
`api` — the reset procedure is in
[Migrating an existing install](modules/migrating-an-existing-install.md#6-reset-the-search-index-then-let-it-rebuild).

Two things that make this worse:

- `indexSync` runs **only at api startup**, so a restart is what triggers it.
- It skips any backlog below `MEILI_SYNC_THRESHOLD` (default **1000**), so a small
  restore is skipped in silence even once the flags are right.

!!! warning "`npm run reset-meili-sync` performs the reset and then hangs forever"
    It prompts twice on stdin using a fresh readline interface each time; with piped
    input the first swallows the whole buffer and closes, and the second waits on an
    exhausted stream. SIGTERM does not clear it — only restarting the container does.
    The reset itself has already committed by the time it hangs.

### If it is not a restore

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

**Then check the objects themselves are still there**, which is a different question and
the more likely answer:

```bash
aws s3api head-object --bucket "$BUCKET" --key "images/<userId>/<name>"
```

A lifecycle rule that expires objects deletes the **bytes but not the database
records**, so the application goes on advertising attachments that no longer exist.
Nothing errors — it is behaving correctly on the data it has. This is how Maryland Legal
Aid lost 71% of its legacy files without noticing for months.

See [S3 and legacy file storage](modules/storage-s3-legacy.md#check-your-bucket-is-still-there).

## An image will not load, but documents are fine

Expected, if the person is signed out. `secureImageLinks: true` requires a session **and**
a path matching the requesting user's own id, so an image URL returns **401** with no
session and **403** for somebody else's image.

The consequence to know about: **images in publicly shared conversations do not load for
signed-out viewers.** That is the cost of the setting, and it is deliberate — without it
the entire image directory is served to anyone holding a URL. See
[Compliance](compliance.md).

If an image fails for its *own* signed-in owner, that is a real fault. Check the file
exists on the data disk at the path the database records.

## One user's avatar is missing

Avatars are stored as a plain path on the user document, with **no `files` record** — so
nothing reports them missing and no integrity check covers them.

After a migration, the usual cause is an avatar set on the old host after the last file
copy. Diff the two machines' image trees; see
[Migrating an existing install](modules/migrating-an-existing-install.md#4-copy-the-uploaded-files).

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

### Sign-in fails with `AADSTS50011` / redirect URI mismatch

If the rejected URI in the error ends in the literal word **`undefined`** —
`https://chat.yourorg.org` **`undefined`** — then `OPENID_CALLBACK_URL` is not set.
LibreChat builds its redirect as `DOMAIN_SERVER + OPENID_CALLBACK_URL`, so an absent
value concatenates the string `undefined` and no provider will ever match it.

```bash
az keyvault secret set --vault-name "$VAULT" \
  --name OPENID-CALLBACK-URL --value "/oauth/openid/callback" --output none
```

It is a **path**, not a full URL, and it needs the leading slash. Then redeploy, and
confirm what the running process actually holds:

```bash
docker compose exec api sh -lc 'echo "$DOMAIN_SERVER$OPENID_CALLBACK_URL"'
```

That result must appear verbatim in your identity provider's registered redirect URIs.
`scripts/check-secrets.sh` catches all three variants of this — absent, given as a full
URL, and missing the leading slash.

### A secret you set had no effect at all

Check you wrote it to the vault the deployment actually reads. If the resource group
holds more than one Key Vault — one left behind by an earlier attempt is the usual way
this happens — then the obvious lookup returns whichever the API listed first, which
need not be yours:

```bash
az keyvault list -g rg-librechat-prod -o table          # more than one row?
```

Every command in these docs filters on the `kv-` prefix, because that is what the
template always names its vault:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)
```

The authoritative answer is on the machine itself — this is the name `deploy.sh` and
`render-env.sh` really use, and it cannot disagree with reality:

```bash
az ssh vm -g rg-librechat-prod -n vm-librechat-prod -- -o IdentitiesOnly=yes \
  'grep KV_NAME /etc/librechat-deploy.conf'
```

This failure is quiet in both directions: writing to the wrong vault succeeds, and the
deploy that ignores it also succeeds. Nothing reports an error — the setting simply
never takes.

### A `Caddyfile` change had no effect, and the reload said it worked

The file on disk is right, the deploy said `deployed … successfully`, `caddy reload` exited
0 — and the proxy is still serving the old configuration. It will keep doing so indefinitely.

Compare the file the container sees against the one on the host:

```bash
sudo stat -c 'host  inode=%i  mtime=%y' /srv/librechat/app/Caddyfile
sudo docker exec caddy stat -c 'cntr  inode=%i  mtime=%y' /etc/caddy/Caddyfile
```

**Different inodes is the answer.** Docker bind-mounts a *single file* by inode, not by path.
`deploy.sh` updates the checkout with `git reset --hard`, which writes a replacement file — a
new inode — so the container goes on reading the old one. `caddy reload` then dutifully
re-reads that stale file and reports success, which is why this looks like a working change
rather than a broken one.

`docker restart caddy` does **not** help: restarting reuses the same container and the same
stale mount. The container has to be recreated:

```bash
cd /srv/librechat/app
sudo docker compose -f compose.yaml -f compose.storage.disk.yml up -d --force-recreate caddy
```

Then verify against the wire rather than a log line — `curl -I` for whatever header or route
you changed.

Two things this does *not* affect. Directory mounts such as `./scripts` follow the path and
are fine. And `librechat.runtime.yaml` escapes it by accident: `deploy.sh` generates that file
with a shell redirect, which truncates the existing file and keeps its inode.

Anything that changes a Caddy **environment variable** — `CHAT_DOMAIN`, `ADMIN_DOMAIN`,
`ACME_EMAIL` — recreates the container by itself, so those changes never show this symptom.
It is edits to the `Caddyfile` alone that do.

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
