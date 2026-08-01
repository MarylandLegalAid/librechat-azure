# Upgrading LibreChat

Renovate opens a pull request when a new LibreChat release ships. The pull request
changes one line in `compose.yaml`:

```yaml
image: ghcr.io/danny-avila/librechat:v0.8.7
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
  "https://raw.githubusercontent.com/danny-avila/LibreChat/v0.8.8/librechat.example.yaml"

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
curl -fsSL "https://raw.githubusercontent.com/danny-avila/LibreChat/v0.8.8/docker-compose.yml" \
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

!!! warning "A restored copy is not a faithful copy until you fix two things"
    Conversation search and document chat both come back broken from a database restore,
    and neither reports it — so an upgrade tested against a naive restore tells you
    nothing about either. See
    [Test your restore](backups.md#test-your-restore) before you trust the comparison.
