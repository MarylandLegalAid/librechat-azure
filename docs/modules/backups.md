# Backup and restore

Two backups. They protect against different things, and you need both.

| | What it protects | How you restore |
|---|---|---|
| **Azure Backup** | The whole machine, including the data disk — so **uploaded files**, letterheads and certificates | Azure Portal, restore the VM or a disk |
| **Nightly database dump** | The databases only: users, conversations, agents, and the document-chat embeddings | `scripts/restore.sh` |

Azure Backup is the one that brings uploaded files back. Now that files live on the
data disk rather than in an object store, nothing else does.

The database dump is small, portable, and restores onto any host with MongoDB —
including a laptop. It exists because a whole-machine restore is a heavy instrument
for "somebody deleted a conversation".

Each night produces **two files with the same timestamp**: `librechat-<time>.archive.gz`
(MongoDB) and `vectordb-<time>.sql.gz` (the embeddings from pgvector, data only). They
belong together. MongoDB holds the record of each uploaded document; pgvector holds what
the document says. `restore.sh` pairs them by timestamp and refuses to restore one without
the other unless you tell it to.

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

You want a `librechat-` and a `vectordb-` blob from last night, each tens of megabytes or
more. If the vector dump fails, the script still uploads the MongoDB dump and then exits
with an error, so the timer shows as failed.

The dump script refuses to upload anything smaller than a megabyte. A dump measured in
kilobytes means `mongodump` wrote an error where your data should be, and uploading it
would quietly replace a good backup with a useless one.

## Test your restore

**An untested backup is not a backup.** This takes about fifteen minutes and is the
only way to find out which one you have.

Do it quarterly. Put it in a calendar.

```bash
# Restore the most recent nightly backup. THIS REPLACES THE DATABASES —
# do it on staging, or on a machine you are willing to lose.
scripts/restore.sh --from-blob latest
```

The script tells you how many user accounts it is about to destroy and makes you type
`restore` to continue.

### What the script restores, and what it checks

A LibreChat backup is three stores, and **each one fails silently** if a restore leaves it
out. The site loads, old conversations open, and you would only notice by searching or by
asking about an old document. So the script handles all three, then checks them before it
says the restore is good:

| Store | What the script does | What it checks afterwards |
|---|---|---|
| MongoDB | `mongorestore --drop` | The application answers its health check |
| pgvector (document chat) | Replaces the embeddings with the paired vector dump, in one transaction: all of it or none of it | The table holds exactly as many embeddings as the dump, and their dimensions match what this host had before. A mismatch means the embedding model differs, and document chat would return nonsense |
| Meilisearch (conversation search) | Clears the `_meiliIndex` flags and empties the search indexes, so LibreChat rebuilds them when it starts | Waits up to 15 minutes for search to hold at least 98% of the conversations in MongoDB |

If any check fails, the script exits with an error and says which. **Don't treat the
instance as good** until you know why.

Why search needs the reset: a restored dump carries `_meiliIndex: true` on every
document, because those documents really were indexed, in the *source* machine's
Meilisearch. Without the reset, LibreChat believes the index is complete and never
rebuilds it. The reset script is `scripts/reset-meili-flags.js`; the background is in
[Migrating an existing install](migrating-an-existing-install.md#6-reset-the-search-index-then-let-it-rebuild).

Afterwards, by hand: sign in, open an old conversation, **search for a phrase you know
exists**, and ask a document-chat question about a file indexed before the restore.

!!! warning "Backups from before vector dumps existed"
    Those have no `vectordb-` file. The script refuses them until you add
    `--skip-vectordb`, which restores MongoDB and leaves this host's vector database alone.
    Document chat then answers **without consulting** any document whose embeddings aren't
    already on this host, and it does so with no error.

!!! note "Restoring from a local file"
    `scripts/restore.sh /path/librechat.archive.gz --vectordb /path/vectordb.sql.gz`.
    The vector file is the same data-only SQL format the migration guide produces, so either
    one works here.

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
