# Backup and restore

Two backups. They protect against different things, and you need both.

| | What it protects | How you restore |
|---|---|---|
| **Azure Backup** | The whole machine, including the data disk — so **uploaded files**, letterheads and certificates | Azure Portal, restore the VM or a disk |
| **Nightly database dump** | The database only: users, conversations, agents | `scripts/restore.sh` |

Azure Backup is the one that brings uploaded files back. Now that files live on the
data disk rather than in an object store, nothing else does.

The database dump is small, portable, and restores onto any host with MongoDB —
including a laptop. It exists because a whole-machine restore is a heavy instrument
for "somebody deleted a conversation".

## Both are on by default

Azure Backup is declared in `infra/main.bicep`: daily, 30-day retention. The nightly
dump runs from a systemd timer at 03:17 UTC and uploads to the storage account the
template created.

Confirm the dump is configured:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret show --vault-name "$VAULT" \
  --name BACKUP-STORAGE-ACCOUNT --query value -o tsv
```

If that is empty, the timer fails nightly and tells you why in its logs. Set it to the
storage account name from the deployment outputs.

## Checking they are running

```bash
# Azure Backup
az backup item list \
  --resource-group rg-librechat-prod \
  --vault-name rsv-librechat-prod \
  --output table

# The nightly dump
az storage blob list \
  --account-name <your backup storage account> \
  --container-name mongo-backups \
  --auth-mode login \
  --query "[].{name:name, size:properties.contentLength, when:properties.creationTime}" \
  --output table
```

You want a blob from last night, tens of megabytes in size.

The dump script refuses to upload anything smaller than a megabyte. A dump measured in
kilobytes means `mongodump` wrote an error where your data should be, and uploading it
would quietly replace a good backup with a useless one.

## Test your restore

**An untested backup is not a backup.** This takes five minutes and is the only way
to find out which one you have.

Do it quarterly. Put it in a calendar.

```bash
# Restore the most recent nightly dump. THIS REPLACES THE DATABASE —
# do it on staging, or on a machine you are willing to lose.
scripts/restore.sh --from-blob latest
```

The script tells you how many user accounts it is about to destroy and makes you type
`restore` to continue.

After it finishes: sign in, open an old conversation, and **search for a phrase you know
exists**. Then ask a document-chat question about a file that was indexed before the
restore.

!!! danger "Two things a database restore does not bring back, and neither reports a problem"
    **The restore test passes with both of these broken.** The database comes back, the
    site loads, and you would only notice by searching or by asking about an old
    document.

    **1. Conversation search.** A restored dump carries `_meiliIndex: true` on every
    document, so LibreChat believes the index is already built and skips the sync. Your
    index is empty. Nothing logs an error. Verify against Meilisearch itself:

    ```bash
    docker compose exec -T meilisearch \
      curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://127.0.0.1:7700/stats
    ```

    If the counts are far below MongoDB's, clear the flags and restart `api` — procedure
    in [Migrating an existing install](migrating-an-existing-install.md#6-reset-the-search-index-then-let-it-rebuild).

    **2. Document chat.** The embeddings live in pgvector, not MongoDB, so this dump
    never contained them. If you restored the database onto a machine whose vector
    database does not match, document chat answers **without consulting your documents**
    — confidently, and without an error. The vector data is on the data disk, so an
    Azure Backup restore covers it; a database-only restore does not.

!!! note "The dump does not include uploaded files"
    Restoring the database alone leaves attachments that appear in conversations and
    will not open. For a full recovery you need the Azure Backup restore point too.

    This is worth understanding *before* you need it.

!!! warning "Anything you fixed in the database gets undone"
    A restore replaces the database wholesale, including repairs you made to agents,
    file records or product naming. If you have such fixes, they must exist as
    idempotent scripts you re-run after every restore — not as remembered actions. See
    [Migrating an existing install](migrating-an-existing-install.md#7-re-apply-anything-the-restore-overwrote).

## Restoring the whole machine

Azure Portal → Recovery Services vault → **Backup Items** → your VM → **Restore VM**.

Two options worth knowing apart:

- **Replace existing** — restores over the current machine. Fastest, and destroys
  whatever is there now.
- **Create new** — restores alongside. Slower, and lets you look before committing.
  Choose this unless you are certain.

You can also restore **just the data disk** and attach it to the running machine,
which is usually what you want if the operating system is fine and the data is not.

## Changing retention

Azure Backup retention is in `infra/main.bicep`:

```bicep
retentionDuration: {
  count: 30
  durationType: 'Days'
}
```

Longer retention costs more storage. Thirty days covers "we noticed a week later",
which is the realistic case. Regulatory retention obligations are a different question
and probably not something a VM backup should be answering — see
[Compliance](../compliance.md).

Dump retention:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret set --vault-name "$VAULT" \
  --name BACKUP-RETENTION-DAYS --value "60" --output none
```

## Why the dump format matters

`scripts/restore.sh` consumes exactly what `scripts/backup-mongo.sh` produces, and a
[migration](migrating-an-existing-install.md) uses the same path.

That is deliberate. The backup format gets exercised constantly rather than only in an
emergency, which is the difference between a backup and a hopeful assumption.
