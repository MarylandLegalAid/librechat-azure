# Migrating an existing install

Moving a running LibreChat onto this blueprint. Written for the case that matters:
real users, real conversations, real stored credentials, and a maintenance window
measured in hours.

One procedure serves both the rehearsal and the real thing. They differ only in
whether writes are frozen and whether DNS moves. **Rehearse at least twice.**

## ⚠️ Before anything else: `CREDS_KEY` and `CREDS_IV`

These two values encrypt every API key your users have saved.

Generating new ones does not produce an error and does not lose any data you can see.
It makes every stored key **permanently undecryptable**, and you find out days later
when users report their keys stopped working. There is no recovery — not from a
backup, not from support, not at all.

Copy them from the old host **before you touch anything else**.

### Transfer them machine to machine

Never paste these into a chat window, a ticket, a document, or your shell history.
There is no reason for a human to see them at all.

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)
OLD_RG=<old resource group>
OLD_VM=<old vm name>

for k in CREDS_KEY CREDS_IV; do
  v=$(az vm run-command invoke -g "$OLD_RG" -n "$OLD_VM" \
        --command-id RunShellScript \
        --scripts "grep -m1 '^${k}=' /srv/LibreChat/.env | cut -d= -f2-" \
        --query "value[0].message" -o tsv \
      | sed -n '/^\[stdout\]/,/^\[stderr\]/p' | sed '1d;$d' | tr -d '\r\n')
  [ -n "$v" ] || { echo "FAILED to read $k"; exit 1; }
  az keyvault secret set --vault-name "$VAULT" --name "${k//_/-}" --value "$v" --output none
  unset v
done
```

!!! danger "Test the extraction on something harmless first"
    `az vm run-command` wraps its output:

    ```
    Enable succeeded:
    [stdout]
    <the value>
    [stderr]
    ```

    The `sed` pipeline strips that framing. **Run it against `APP_TITLE` first** and
    confirm you get back exactly the title and nothing else. A mis-parse that
    captures wrapper text writes a corrupt key, and you would not find out until
    users' saved keys failed to decrypt after cutover.

### Verify by checksum, never by eye

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

# on the old host, via run-command
grep -m1 '^CREDS_KEY=' /srv/LibreChat/.env | cut -d= -f2- | tr -d '\r\n' | sha256sum

# from your workstation
az keyvault secret show --vault-name "$VAULT" -n CREDS-KEY \
  --query value -o tsv | tr -d '\r\n' | sha256sum
```

The two hashes must match exactly. This is the verification step. Do not skip it and
do not substitute "it looked right".

## The other secrets

| Secret | What to do |
|---|---|
| `CREDS-KEY`, `CREDS-IV` | **Copy verbatim.** See above. |
| `JWT-SECRET`, `JWT-REFRESH-SECRET` | Reuse or regenerate. Regenerating forces one re-login for everyone. Fine. |
| `MEILI-MASTER-KEY` | Either. The index rebuilds from the database regardless. |
| `ADMIN-PANEL-SESSION-SECRET` | **New in v0.8.7 and required.** `openssl rand -hex 32`. The panel refuses to start without it. |
| Provider API keys, OIDC, SMTP | Copy across. |
| `AWS-*` | **Keep them** if you have files in S3. See [S3 and legacy file storage](storage-s3-legacy.md). |
| `ASSISTANTS_API_KEY` | Do not migrate. If the `assistants` endpoint is not in `ENDPOINTS`, it is dead config. |

## Rehearsal

Do this on the new machine while the old one is still serving users. Nothing here
touches the old host except to read from it.

### 1. Take a copy — without stopping anything

```bash
docker exec chat-mongodb mongodump --archive --gzip --db LibreChat > /tmp/librechat.archive.gz
ls -lh /tmp/librechat.archive.gz
```

Check the size. Tens of megabytes is right. Kilobytes means `mongodump` wrote an
error where your data should be.

### 2. Move it across

Azure Blob with a short-lived SAS, or `scp` directly between the two hosts. Whichever
you use, **delete the artifact afterwards** — it is a complete copy of confidential
data.

### 3. Restore

```bash
scripts/restore.sh /path/to/librechat.archive.gz
```

`--drop` makes this re-runnable: a second rehearsal cleanly discards the first.

### 4. Copy the uploaded files

**This is the step people forget**, and it is new if you are coming from an
S3-backed deployment.

```bash
rsync -av /srv/LibreChat/uploads/ newhost:/srv/librechat/data/uploads/
rsync -av /srv/LibreChat/images/  newhost:/srv/librechat/data/images/

# the container runs as uid 1000 and will not be able to write otherwise
ssh newhost 'sudo chown -R 1000:1000 /srv/librechat/data/uploads /srv/librechat/data/images'
```

Restoring the database without the files leaves attachments that appear in
conversations and will not open.

### 5. Let search rebuild

Meilisearch reindexes from the database on its own. Search for a phrase you know
exists in an old conversation and confirm you get a hit. **Time how long this takes** —
that number is part of your maintenance window estimate, and guessing it is how
windows overrun.

### 6. Migrate agent models

If your approved model list has changed, every agent pointing at a dropped model needs
moving — including its version history, because reverting an agent resurrects whatever
model that version used.

```bash
scripts/migrate-agent-models.sh --dry-run
```

Read every line. Compare the totals against what you expect. Then:

```bash
scripts/migrate-agent-models.sh --apply
```

See [Adding and retiring models](models.md#migrating-agents-off-a-dropped-model).

### 7. Smoke test

The full list is below. Do all of it.

### 8. Rehearse again

At least once more, end to end. Steps 3 and 4 are destructive and idempotent, so a
re-run discards the previous attempt cleanly.

## Cutover

1. **At least 24 hours ahead**, lower the DNS TTL on your production hostname to 60
   seconds. A forgotten TTL is the single most common cause of a cutover that "works"
   but leaves half your users on the old machine.
2. Announce the window.
3. Freeze writes: `docker stop LibreChat` on the old host. **Leave its database
   running** — you still need to dump from it.
4. Re-run rehearsal steps 1–6 exactly. This wipes your rehearsal test data too.
5. Smoke test on the staging hostname.
6. Move DNS to the new address. Update `CHAT-DOMAIN`, `ADMIN-DOMAIN`,
   `DOMAIN-CLIENT`, `DOMAIN-SERVER` and `ADMIN-PANEL-URL` in the key vault, then
   `deploy.sh --force` so Caddy issues certificates for the production names.
7. Smoke test again on the production hostname, **including a real SSO login**.
8. Stop-deallocate the old machine. Keep it for two weeks.
9. **Delete the transfer artifact.** It is a full copy of confidential data.

## Rollback, honestly

Restart the old machine and point DNS back.

That works for **hours, not days**. The moment people start writing to the new
instance, rolling back silently discards their work. Past roughly the first business
day, the real recovery path is fixing forward. Say this out loud to whoever owns the
decision, before the window rather than during it.

## Smoke test

- [ ] Login succeeds; an existing user's conversation history is present
- [ ] A user with a stored provider API key can still use it — **this is what proves
      `CREDS_KEY` carried over**
- [ ] Send a message on every approved model
- [ ] On each model that needs special routing, a conversation **that uses a tool**
      (a plain "hello" does not test it — see
      [GPT-5.6 and the Responses API](models-gpt56-responses.md))
- [ ] Edit and save a migrated agent through the Agent Builder UI, then run a
      tool-calling conversation on it
- [ ] Conversation search returns results
- [ ] Upload a new file, confirm it renders, and confirm it landed on the data disk
- [ ] Open an **old** attachment from before the migration — proves legacy S3 records
      still serve
- [ ] File chat returns grounded answers on an existing document — proves the vector
      database and embeddings survived
- [ ] Speech-to-text transcribes an audio upload
- [ ] Image generation returns an image
- [ ] Every agent loads and responds
- [ ] Each MCP tool server responds
- [ ] Admin panel loads, an admin can list users, **and a non-admin is refused**
- [ ] Run Code executes, if you have a code interpreter
- [ ] `/api/health` returns healthy and the availability alert is green
