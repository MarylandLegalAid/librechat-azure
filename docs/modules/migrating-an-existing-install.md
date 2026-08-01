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
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)
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
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

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
# --exclude temp/ : scratch for the document-chat pipeline, often the bulk of the
# directory, and none of it is worth moving
rsync -av --exclude 'temp/' /srv/LibreChat/uploads/ newhost:/srv/librechat/data/uploads/
rsync -av /srv/LibreChat/images/  newhost:/srv/librechat/data/images/

# the container runs as uid 1000 and will not be able to write otherwise
ssh newhost 'sudo chown -R 1000:1000 /srv/librechat/data/uploads /srv/librechat/data/images'
```

Restoring the database without the files leaves attachments that appear in
conversations and will not open.

!!! danger "Avatars have no database record, so nothing reports them missing"
    User avatars are stored as a plain path on the user document — there is no `files`
    row for them. If your old host writes avatars locally, any avatar set **after** your
    last file copy exists on that machine and nowhere else.

    A restore does not touch the data disk, which makes it tempting to reason that the
    files are already handled. That reasoning is right about the restore and wrong about
    the migration. **Re-run this copy at cutover, and diff both trees before you
    decommission the old machine:**

    ```bash
    ssh oldhost 'sudo find /srv/LibreChat/images -type f -printf "%P\n" | sort' > old.txt
    ssh newhost 'sudo find /srv/librechat/data/images -type f -printf "%P\n" | sort' > new.txt
    comm -23 old.txt new.txt      # anything here exists only on the old machine
    ```

    Maryland Legal Aid's cutover found exactly one file this way, thirteen hours after
    the last sync. It would have been unrecoverable two weeks later.

### 5. Copy the vector database

**If you use document chat, the embeddings are not in MongoDB and nothing above moves
them.** They live in pgvector, in its own database on the data disk.

Skip this and document chat keeps working — it simply answers **without ever consulting
your documents**. No error, no empty result, just ungrounded answers about files the
system appears to have read.

```bash
ssh oldhost 'sudo docker exec vectordb pg_dump -U <olduser> -d <olddb> \
  --data-only --table=langchain_pg_collection --table=langchain_pg_embedding | gzip -c' \
| ssh newhost 'cat > /tmp/pgvector.sql.gz'

# on the new host — truncate first, or the restore collides with the seed collection
C="docker compose -f compose.yaml -f compose.storage.disk.yml"
$C exec -T vectordb psql -U librechat -d librechat -v ON_ERROR_STOP=1 \
  -c "TRUNCATE langchain_pg_embedding, langchain_pg_collection CASCADE;"
zcat /tmp/pgvector.sql.gz | $C exec -T vectordb psql -U librechat -d librechat -v ON_ERROR_STOP=1 -q
```

The database and role names usually differ between the two hosts; a `--data-only` dump
does not care, as long as the schemas match.

Verify **against the old host**, not against expectations:

```sql
SELECT c.name, COUNT(e.uuid) AS embeddings,
       COUNT(DISTINCT (e.cmetadata->>'file_id')) AS distinct_files
FROM langchain_pg_collection c
LEFT JOIN langchain_pg_embedding e ON e.collection_id = c.uuid GROUP BY c.name;

SELECT DISTINCT vector_dims(embedding) FROM langchain_pg_embedding;
```

!!! danger "If the vector dimensions differ between hosts, stop"
    Different dimensions mean the embedding model changed. The vectors are not
    interchangeable, and restoring them produces confident nonsense rather than an
    error. Fix the model mismatch first — see
    [Adding and retiring models](models.md).

### 6. Reset the search index, then let it rebuild

**Meilisearch does not reindex itself after a restore, and the failure is silent.**

`indexSync` does not ask Meilisearch how many documents it holds. It reads a
`_meiliIndex` flag **on the MongoDB documents** — and a dump restored from another
machine carries that flag set `true`, because those documents really were indexed, in
the *old* machine's Meilisearch. So the new instance believes the index is already
built, skips the sync, and conversation search stays dead with nothing in any log.

Clear the flags, then restart `api`:

```bash
docker compose exec -T mongodb mongosh LibreChat --quiet --file /tmp/reset-meili.js
docker compose restart api      # indexSync runs ONLY at api startup
```

where `/tmp/reset-meili.js` is:

```js
const retention = {$or:[
  {isTemporary:false, expiredAt:null},
  {isTemporary:false, expiredAt:{$gt:new Date()}},
  {isTemporary:null,  expiredAt:null}
]};
for (const name of ["messages","conversations"]) {
  const r = db.getCollection(name).updateMany(
    Object.assign({}, retention, {_meiliIndex:{$ne:false}}),
    {$set:{_meiliIndex:false}}
  );
  print("  " + name + ": modified=" + r.modifiedCount);
}
```

Two further traps: `indexSync` runs **only at startup**, so the restart is what
triggers it, and it skips any backlog below `MEILI_SYNC_THRESHOLD` (default **1000**) —
so a small restore can be skipped even with the flags cleared.

!!! warning "Do not use `npm run reset-meili-sync`"
    It performs the reset correctly and then **hangs forever**. It asks two questions on
    stdin using a fresh readline interface per prompt; with piped input the first
    swallows the whole buffer and closes, and the second waits on an exhausted stream.
    The reset itself has already committed by then. Only restarting the container clears
    it. In a one-hour window this blocks the sequence.

Verify against **Meilisearch itself**, not the application's logs:

```bash
docker compose exec -T meilisearch \
  curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://127.0.0.1:7700/stats
```

`convos` should equal the conversation count in MongoDB. `messages` may land slightly
**under** it — Meilisearch keys on `messageId`, and duplicates collapse. A gap of tens
is normal; a gap of thousands is not.

**Time this.** It is part of your window estimate. Expect a couple of minutes, and
expect the count to sit still for a while before jumping — checking too early looks like
failure.

!!! note "Check a few minutes after the restore, not immediately"
    Expired and temporary conversations are deliberately skipped by the reset and then
    deleted by MongoDB's TTL shortly afterwards, so the totals move under you and
    briefly look like a shortfall that is not there.

### 7. Re-apply anything the restore overwrote

A restore replaces the database wholesale, so **every database-side fix you have ever
made comes undone**, including ones made minutes earlier during the same window. Any
such repair must be a re-runnable script, not a remembered action.

If your approved model list has changed, every agent pointing at a dropped model needs
moving — including its version history, because reverting an agent resurrects whatever
model that version used.

```bash
scripts/migrate-agent-models.sh --dry-run
```

Read every line. Compare the totals against what you expect. **If they differ from what
you predicted, stop and find out why before applying** — a difference is not
automatically a fault, but it must be explainable. Then:

```bash
scripts/migrate-agent-models.sh --apply
```

See [Adding and retiring models](models.md#migrating-agents-off-a-dropped-model).

Anything else that lives in the database belongs here too, and the list is
deployment-specific: agent instructions and tool selections, product naming that appears
in agent records, and file records rewritten by a storage migration. Write each one as
an **idempotent script with a dry run**, run them after *every* restore, and keep an
audit trail — you will run them at least twice, once in rehearsal and once for real,
and probably a third time when you are unsure whether you already did.

### 8. Smoke test

The full list is below. Do all of it.

### 9. Rehearse again

At least once more, end to end. Steps 3 through 7 are destructive and idempotent, so a
re-run discards the previous attempt cleanly.

**Rehearse twice, not once.** The second rehearsal is not a repeat — the first one
tells you what your procedure does, and the second tells you what your procedure is
*missing*. Maryland Legal Aid's second rehearsal is what found that the vector database
had never been migrated at all: nothing errored, because the first rehearsal's instance
had the same gap and reported itself perfectly healthy.

## Cutover

1. **At least 24 hours ahead**, lower the DNS TTL on your production hostname. 60
   seconds is ideal; some providers enforce a floor of 300. A forgotten TTL is the
   single most common cause of a cutover that "works" but leaves half your users on the
   old machine.
2. Announce the window.
3. **Confirm you can still reach the new machine.** If SSH is restricted to an IP
   allowlist, check *now* that your current address is on it — a connection timeout on
   port 22 in the middle of a window is an expensive way to discover you are working
   from a different network than usual. See
   [When it breaks](../troubleshooting.md#locked-out-of-ssh).
4. Freeze writes: `docker stop LibreChat` on the old host. **Leave its database
   running** — you still need to dump from it.
5. **Record the frozen counts** — users, conversations, messages, agents, files. These
   are what you verify the restore against, and they are only trustworthy once writes
   have stopped.
6. Re-run rehearsal steps 1–7 exactly. This wipes your rehearsal test data too, and it
   re-copies any file written on the old host since your last sync.
7. Smoke test on the staging hostname.
8. Move DNS to the new address. Update `CHAT-DOMAIN`, `ADMIN-DOMAIN`,
   `DOMAIN-CLIENT`, `DOMAIN-SERVER` and `ADMIN-PANEL-URL` in the key vault, then
   `deploy.sh --force` so Caddy issues certificates for the production names.
9. Smoke test again on the production hostname, **including a real SSO login**.
10. **Diff the file trees** between old and new one last time (step 4), before the old
    machine goes away.
11. Stop-deallocate the old machine. Keep it for two weeks.
12. **Delete the transfer artifacts.** They are full copies of confidential data.

!!! warning "Wait for DNS properly before step 8, or you can lose an hour to a rate limit"
    Certificates are issued by Let's Encrypt, which proves you control the name by
    resolving it — through the **authoritative** nameservers, not your resolver. Failed
    validations are capped at **5 per hostname per hour**, so deploying into a
    half-published zone can lock out issuance for an hour.

    "Propagated" is not yes-or-no. Large DNS providers front their nameservers with
    anycast, so during a publish different nodes answer with different zone versions and
    the *same* nameserver returns the old and new address alternately. Maryland Legal
    Aid saw a zone sit at roughly 50/50 for ten minutes, with a naive "all nameservers
    agree" check passing once by luck and immediately breaking.

    Sample repeatedly and require a percentage:

    ```bash
    for rep in $(seq 1 12); do
      for ns in $(dig +short NS yourorg.org); do
        dig +short chat.yourorg.org @"$ns"
      done
    done | sort | uniq -c
    ```

    Go when essentially every answer is the new address — and check the admin hostname
    too. A brand-new record often lags an edited one.

!!! note "Anything you changed by hand on the machine, change in the template too"
    If you edit a Bicep parameter live — an SSH allowlist entry, for instance — the next
    template deployment silently reverts it. That matters mid-cutover, because
    repointing the availability-test URL *is* a template deployment, and it would undo
    the allowlist entry keeping you connected.

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
- [ ] Conversation search returns results — **check this every time; it is the failure
      that hides behind a successful restore** (step 6)
- [ ] Upload a new file, confirm it renders, and confirm it landed on the data disk
- [ ] Open an **old** attachment from before the migration — proves legacy file records
      still serve. If it does not open, confirm the bytes still exist before assuming
      the migration broke it; see
      [S3 and legacy file storage](storage-s3-legacy.md#check-your-bucket-is-still-there)
- [ ] **User avatars still render**, including for someone who is not you. Avatars have
      no database record, so a missing one is invisible until a person notices
- [ ] **Images require a session, in both directions.** Signed out, an image URL must
      return **401**; signed in, your own image must return **200**. Check both — a
      regression that returns 403 to everyone passes the signed-out half on its own, and
      would go unnoticed until users reported missing images
- [ ] A conversation containing an image still renders in the browser
- [ ] File chat returns grounded answers on an existing document — proves the vector
      database and embeddings survived (step 5). If none of the indexed documents belong
      to you, upload a fresh one and ask a question only it can answer
- [ ] **Your product naming reads correctly** everywhere it appears — browser tab,
      footer, welcome line, terms modal, and any agent whose name contains it. These come
      from different places, and a restore only reverts the ones stored in the database
- [ ] Speech-to-text transcribes an audio upload
- [ ] Image generation returns an image
- [ ] Every agent loads and responds
- [ ] Each MCP tool server responds
- [ ] Admin panel loads, an admin can list users, **and a non-admin is refused**
- [ ] Run Code executes, if you have a code interpreter
- [ ] `/health` returns healthy and the availability alert is green
