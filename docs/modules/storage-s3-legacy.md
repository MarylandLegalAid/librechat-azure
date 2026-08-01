# S3 and legacy file storage

Uploaded files go on the virtual machine's data disk. This page explains why, what to
do if yours are currently in S3, and why Azure Blob is not an option.

## The default: local disk

`FILE_STORAGE=disk` writes uploads and generated images to the mounted Azure data
disk, which Azure Backup protects along with everything else on it.

Three reasons this is the default:

- **One agreement instead of two.** Files never leave your Azure subscription, so your
  BAA with Microsoft covers them. Adding an object store means a second vendor
  relationship and a second agreement to negotiate. See [Compliance](../compliance.md).
- **No expiring links.** Object storage serves private files through presigned URLs
  that expire. The application serving its own files sidesteps that whole category of
  problem.
- **It is the simplest thing that works**, and the only topology an organization
  without dedicated IT staff can reason about.

The cost is that files live on one machine's disk. That is what
[backups](backups.md) are for, and why Azure Backup is on by default.

## Why not Azure Blob

Azure Blob would be the natural choice on Azure, and it was evaluated properly and
rejected on a **verified technical limitation**, not preference.

In LibreChat v0.8.7, `api/server/services/Files/Azure/crud.js` returns
`blockBlobClient.url` — the raw blob URL. There is **no SAS-generation code anywhere
in the repository**: `generateBlobSASQueryParameters` and `BlobSASPermissions` have no
hits.

That leaves two configurations, and neither is acceptable:

| `AZURE_STORAGE_PUBLIC_ACCESS` | Result |
|---|---|
| `false` | The container is private, so those URLs return **403**. Files do not load. |
| `true` | The container is **world-readable**. Anyone with a URL has the file. |

For an organization holding confidential client information, the second is
disqualifying and the first does not work.

Re-check this if a future LibreChat release adds SAS support. Until then, do not
spend time on it.

## Migrating off S3 without moving anything

If you are moving an existing LibreChat that used S3, you **can** leave the old files
where they are and point the new deployment at the same bucket.

!!! danger "Read the next section before you rely on this"
    This works only for as long as the objects actually exist. Maryland Legal Aid ran
    this configuration and **71% of the legacy files had already been deleted** by a
    bucket lifecycle rule — silently, months earlier, with every database record intact
    and the application cheerfully advertising attachments that were gone.

    Leaving files in a bucket is not a decision you make once. It is an ongoing
    dependency on that bucket's configuration.

Set `FILE_STORAGE=disk` and **leave your AWS credentials set**:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret set --vault-name "$VAULT" --name AWS-ACCESS-KEY-ID     --value "..."
az keyvault secret set --vault-name "$VAULT" --name AWS-SECRET-ACCESS-KEY --value "..."
az keyvault secret set --vault-name "$VAULT" --name AWS-REGION            --value "us-east-1"
az keyvault secret set --vault-name "$VAULT" --name AWS-BUCKET-NAME       --value "your-bucket"
```

What happens:

- **New** uploads go to the data disk.
- **Existing** file records carry `source: s3` in the database and keep being served
  from the bucket exactly as before.

No bulk copy. No database rewrite. Nothing to go wrong halfway through, because
nothing happens at all.

## Check your bucket is still there

**Do this before you decide to leave anything in S3, and do it against the bucket
rather than the database.**

Maryland Legal Aid ran the configuration above for months. A bucket-wide lifecycle rule
was expiring objects after roughly 45 days. It deleted the **bytes but not the database
records**, so LibreChat kept listing the attachments and rendering them as broken files.

Measured across all 2,045 legacy records by comparing the bucket's key listing against
the keys the database expected:

| Record month | Present | Missing |
|---|---|---|
| 2025-12 → 2026-05 | **0** | 1,312 |
| 2026-06 | 370 | 139 |
| 2026-07 | 224 | 0 |
| **Total** | **594** | **1,451 (71%)** |

A clean age-based cutoff, and **unrecoverable** — bucket versioning was disabled, so
there were no delete markers to restore.

Nothing about this was visible from inside the application. There was no error, no log
line and no failed health check, because the application was behaving correctly on the
data it had. It was found only when somebody opened a year-old conversation and noticed
the images did not load.

```bash
# does the bucket still hold what the database thinks it does?
aws s3 ls "s3://$BUCKET" --recursive | awk '{print $4}' | sort > bucket-keys.txt

# and check what will delete them next
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
aws s3api get-bucket-versioning --bucket "$BUCKET"
```

An empty lifecycle configuration today does not prove the files were never at risk — it
only proves nothing is expiring them right now.

!!! danger "Deleting object storage without deleting the database record produces a broken file, not a missing one"
    This is the general lesson, and it applies to any retention policy you write later,
    on any storage:

    - Delete **both** the stored object and its database record, together.
    - Delete neither.

    Deleting only the bytes leaves the application advertising files it cannot serve,
    and it will do so indefinitely without ever reporting a problem.

    LibreChat v0.8.7 has **no** general file-retention policy of its own — the only
    expiry machinery is temporary-chat retention. Nothing in the application will do
    this to your data disk by itself. If you add age-based cleanup later, that script
    owns both halves.

## Moving the files onto the disk after all

If the bucket turns out to be a liability rather than an archive — which is the
conclusion Maryland Legal Aid reached — copy what still exists onto the data disk and
rewrite those records to `source: local`.

The path mapping is direct, because the S3 key already encodes `<file_id>__<filename>`,
which is exactly the local convention:

```
s3  images/<userId>/<name>   ->  <data disk>/images/<userId>/<name>
s3  uploads/<userId>/<name>  ->  <data disk>/uploads/<userId>/<name>
```

Write it **disk-first** — a file already present at the right size is relinked with no
fetch — so the migration is idempotent, cheap to re-run, and still correct if more
objects have disappeared in the meantime. Verify each write by byte count, and expect
records whose objects are gone to remain `source: s3`; those are not failures, they are
files that no longer exist.

**Re-run it after every database restore.** The bytes on the disk survive a restore; the
records do not, and they revert to `source: s3` along with everything else.

Maryland Legal Aid now runs this: 594 salvaged files serving from disk, 1,451 dead
records deliberately left alone because deleting them edits real conversation history,
and **no user-facing file depending on S3 at all**.

## Running new files on S3 too

If you already run a bucket under an appropriate agreement and would rather keep
files there:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret set --vault-name "$VAULT" --name FILE-STORAGE --value "s3"
```

with the four `AWS-*` secrets set. Then redeploy.

`deploy.sh` selects both halves from that one variable — the `fileStrategy` overlay
and the Compose overlay that omits the bind mounts — so they cannot drift apart.

This path is validated in CI on every pull request precisely because nobody here runs
it day to day. See
[`config/storage/README.md`](https://github.com/MarylandLegalAid/librechat-azure/blob/main/config/storage/README.md).

## Why `fileStrategy` is not just an environment variable

Because it does not work. `fileStrategy` is parsed as a zod enum, and LibreChat
applies `${VAR}` interpolation selectively — not to that key. The literal string
`${FILE_STRATEGY}` reaches the validator, fails to match, and the application refuses
to start.

So the choice is baked in before LibreChat reads the file, by a `yq` merge in
`deploy.sh`. That is the whole reason `config/storage/` exists.
