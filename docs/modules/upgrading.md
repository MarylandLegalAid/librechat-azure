# Upgrading LibreChat

Renovate opens a pull request when a new LibreChat release ships. The pull request
changes one line in `compose.yaml`:

```yaml
image: ghcr.io/librechat-ai/librechat:v0.8.7
```

Merging it deploys the new version within five minutes. Before you merge, work
through this page.

## Why the version is pinned

The previous deployment tracked `librechat-dev:latest`. That is how it silently ended
up on a **pre-release**, several versions behind current, without anyone deciding to.

A pinned tag plus a pull request makes every upgrade a choice somebody made, and gives
you a specific version to name when something is wrong.

## Before merging

### 1. Read the changelog for the whole range

[librechat.ai/changelog](https://www.librechat.ai/changelog), from your current
version forward — not just the newest entry.

Look for:

- **New required environment variables.** These are the ones that hurt.
  `ADMIN_PANEL_SESSION_SECRET` arrived in v0.8.7 with no default, and the admin panel
  refuses to start without it. A missing required variable presents as a crash loop,
  not as a helpful message.
- **Renamed or removed `librechat.yaml` keys.**
- **One-time database migrations.** LibreChat occasionally ships a script that must
  run once.

### 2. Diff the example config — do not trust the prose

This is the step that catches what changelogs miss:

```bash
curl -fsSL -o /tmp/new-example.yaml \
  "https://raw.githubusercontent.com/LibreChat-AI/LibreChat/v0.8.8/librechat.example.yaml"

diff <(yq -P 'sort_keys(..)' /tmp/new-example.yaml) \
     <(yq -P 'sort_keys(..)' librechat.yaml) | head -60
```

You are looking for keys that exist there and not here, and keys that exist here and
are no longer recognized. Renamed and removed keys are the most common upgrade break,
and prose changelogs miss them routinely.

### 3. Check the `version:` key

The top of `librechat.yaml`:

```yaml
version: 1.3.13
```

It should match the new release's own `librechat.example.yaml`. If it changed, bump it
in the same pull request.

### 4. Check the supporting images

Each LibreChat release pins versions of MongoDB, Meilisearch, pgvector and the RAG API
in its own `docker-compose.yml`. Compare against `compose.yaml` here:

```bash
curl -fsSL "https://raw.githubusercontent.com/LibreChat-AI/LibreChat/v0.8.8/docker-compose.yml" \
  | grep 'image:'
```

Most of the time they match and there is nothing to do.

!!! warning "Meilisearch encodes its version in the data path"
    ```yaml
    - ${DATA_DIR}/meili_data_v1.35.1:/meili_data
    ```

    If the Meilisearch version changes, update that path to match. Meilisearch cannot
    read a data directory written by a different version, so the version in the path
    means an upgrade starts with an empty index and rebuilds from MongoDB — slow, but
    safe. Leaving the old path means it crash-loops on a format it does not
    understand.

    Renovate's pull request body reminds you of this.

### 5. Check CI

`validate.yml` renders both storage configurations, parses every Compose profile
combination, and asserts that provider names still resolve. It catches the class of
break that does not appear until a user sends a message.

## Merging

Push to `main`. The machine deploys within five minutes, or immediately if you use the
Actions workflow.

`deploy.sh` waits for the application to report healthy and **rolls back
automatically** if it does not. So a straightforwardly broken upgrade is self-limiting.

What it cannot catch is an upgrade that starts healthy and misbehaves — a renamed
config key that now means something else, or a feature that quietly stopped working.
That is what the smoke test is for.

## Releases with an offline database migration

Some releases need a one-time migration to run **with nothing writing to the
database**, before the new version starts. v0.8.8's tenant-index migration is one:
the old unique indexes conflict with the new ones, and the new version logs
`Index build failed` until the migration has run.

The ordinary path cannot do that. `deploy.sh` pulls the new image and starts it in
one step, and if the start fails, it rolls back automatically. After a migration,
an automatic rollback is the wrong thing: it would put the old version on a
migrated database. So drive this kind of upgrade by hand:

```bash
# 1. A restore point: a fresh dump (and an Azure snapshot of the data disk).
sudo systemctl start librechat-backup.service

# 2. Stop the timer, so it cannot deploy the merge before you are ready.
sudo systemctl stop librechat-deploy.timer

# 3. Merge the upgrade, then on the machine:
cd /srv/librechat/app
sudo git fetch origin main && sudo git reset --hard origin/main
C="docker compose -f compose.yaml -f compose.storage.disk.yml"   # your storage mode
sudo $C pull api

# 4. Stop every writer. Only the API writes to MongoDB; the admin panel goes
#    through it. MongoDB itself stays up.
sudo $C stop api admin-panel

# 4b. v0.8.8: delete duplicate reply placeholders, or step 5 fails with E11000
#     on messages. Read the dry run, then apply. It must report 0 unresolved.
sudo scripts/delete-duplicate-messages.sh
sudo scripts/delete-duplicate-messages.sh --apply

# 4c. v0.8.8: remove agent knowledge files whose S3 object is gone, or those
#     agents' file search fails on every turn. Read the dry run, then apply.
#     It must report 0 "no answer". Skip it if you never used S3 storage.
sudo scripts/remove-dead-agent-files.sh
sudo scripts/remove-dead-agent-files.sh --apply

# 5. Run the migration from the NEW image, as a one-off container.
sudo $C run --rm --no-deps -w /app api npm run migrate:tenant-indexes:dry-run
sudo $C run --rm --no-deps -w /app api npm run migrate:tenant-indexes

# 6. Only if step 5 exited 0: start the new version, and restart the timer.
sudo scripts/deploy.sh --force
sudo systemctl start librechat-deploy.timer
```

Because step 3 already moved the checkout, step 6 sees no change of commit and so
has nothing to roll back to. That is intended. From step 5 on, the way back is a
**restore**, not a revert. If step 5 fails, nothing has been dropped yet: keep the
writers stopped, fix what it reports, and run it again.

A failure in step 5 while it is still *building* indexes (the error names
`createIndex`) leaves a database the old version runs on unchanged. If the fix
is not quick, abandon the window instead: revert the merge, push, and run
`scripts/deploy.sh --force`. Both paths were rehearsed on staging.

Why step 4b exists: v0.8.7 sometimes saves a streaming reply twice, as an
`unfinished` placeholder and as the finished reply, under one `messageId`.
v0.8.8 makes that key unique, and production had 34 such pairs. Users see the
finished copy by default and the placeholder as a stray "1 / 2" version, so
deleting the placeholder changes nothing they rely on. New pairs keep
appearing until the upgrade, so run it in the window, not days ahead. The only
way back is the backup from step 1; the script's audit trail in
`$DATA_DIR/migrations/` lists what it deleted.

Why step 4c exists: v0.8.8 records which vector namespace holds each agent
file. For files embedded before v0.8.8 it has no record, so on an agent's first
file search it reads every knowledge file from storage and embeds it again. If
one read fails, the whole search fails ("Failed to provision N file(s) for
search"), on every turn. v0.8.7 searches the old vectors and never notices a
missing original. Production had 18 agent files with `source: s3` whose objects
were 404 in the bucket: the 17 knowledge files of one agent, and one id left in
an old version snapshot of another. The script removes a file only when its
record says S3 **and** a HEAD of the object, with the deployment's own AWS
settings, returns 404; any other answer stops it before a write. It edits the
agents' version snapshots too, because restoring a version copies its file list
back. Run it in the window, before v0.8.8 starts: on v0.8.7 those agents still
work. `--revert` with the apply's audit trail puts the lists back.

A staging copy usually has no S3 credentials, so the HEAD cannot run there.
Rehearse with `--head-results FILE`, where FILE is the audit trail of a
production dry run (it records each HEAD result, and no file names). Never use
it in production itself.

Rehearse the whole sequence on a [staging copy](#a-note-on-staging) first.

## After merging

```bash
# watch it
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "journalctl -u librechat-deploy.service -n 60 --no-pager" \
  --query "value[0].message" -o tsv

# confirm the version
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "docker compose -f /srv/librechat/app/compose.yaml images api" \
  --query "value[0].message" -o tsv
```

Then a short smoke test:

- [ ] Sign in
- [ ] Send a message on each model family
- [ ] **A conversation that uses a tool** — the case that breaks when endpoint routing
      changes (see [GPT-5.6 and the Responses API](models-gpt56-responses.md))
- [ ] Search returns results
- [ ] Upload a file and open an old attachment
- [ ] Admin panel loads
- [ ] Each MCP tool server responds

## Going back

```bash
git revert <the merge commit>
git push
```

The next deploy puts the previous version back. Because the image tag is pinned, "the
previous version" is a specific, reproducible thing.

!!! danger "Rolling back does not undo a database migration"
    If the release ran a one-time migration, reverting the image leaves an older
    application against a migrated database. That may work, or may not.

    This is the reason step 1 asks you to look for migrations specifically. If a
    release has one, take a backup first and treat the upgrade as one-way.

## A note on staging

There is no permanent staging environment here, and pretending otherwise would be
worse than saying so. For a high-stakes upgrade, deploy a second instance from the
same template pointed at a restored copy of your data, test there, then upgrade
production. `scripts/restore.sh` makes that about a twenty-minute exercise.

!!! warning "Use `restore.sh`, not a bare `mongorestore`"
    Conversation search and document chat both come back broken from a naive database
    restore, and neither reports it, so an upgrade tested against one tells you nothing
    about either. `scripts/restore.sh` restores the vector database too, rebuilds search,
    and checks both. See [Test your restore](backups.md#test-your-restore).
