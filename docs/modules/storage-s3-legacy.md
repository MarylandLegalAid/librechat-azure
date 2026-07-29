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

If you are moving an existing LibreChat that used S3, the useful thing to know is
that **you do not have to move the files**.

Set `FILE_STORAGE=disk` and **leave your AWS credentials set**:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

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

This is what Maryland Legal Aid runs: 2,040 legacy files still served from S3,
everything since on disk. The bucket and its credentials stay indefinitely — they are
not a migration leftover to clean up, they are load-bearing.

!!! warning "Do not delete the bucket"
    Deleting it breaks every attachment older than the migration. There is no
    warning and no error at deploy time; the files simply stop opening.

    If you genuinely want to retire the bucket, you have to copy the objects to the
    data disk **and** rewrite the `source` field on those file records. That is a
    real project, not a cleanup task.

## Running new files on S3 too

If you already run a bucket under an appropriate agreement and would rather keep
files there:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

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
