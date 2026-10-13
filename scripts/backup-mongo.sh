#!/usr/bin/env bash
#
# Nightly database dumps to Azure Blob Storage: MongoDB and the vector database.
#
# This is the second of two backups, and they protect against different things:
#
#   Azure Backup (configured in infra/main.bicep) images the whole VM including
#   the data disk. It is the only thing that restores users' uploaded FILES now
#   that they live on disk rather than in an object store.
#
#   This script produces a small, portable, single-file dump of the DATABASE. It
#   restores onto any host with MongoDB, including a laptop, without Azure being
#   involved at all.
#
#   Alongside it, a dump of the document-chat embeddings from pgvector, taken
#   in the same run and named with the same timestamp so restore.sh can pair
#   them. MongoDB holds the file records; pgvector holds what those files say.
#   Restoring one without the other gives document chat that answers WITHOUT
#   consulting the documents, with no error anywhere. (The file is still named
#   backup-mongo.sh because the systemd unit and cloud-init call it by name.)
#
# The dump matters for a second reason: scripts/restore.sh consumes exactly this
# artifact, and a migration or a staging refresh uses that same path. So this
# backup format gets exercised constantly rather than only in an emergency,
# which is the difference between a backup and a hopeful assumption.
#
# Authentication is the VM's managed identity — no storage account key exists on
# this machine to leak. The identity needs "Storage Blob Data Contributor" on
# the backup storage account; infra/main.bicep grants it.
#
# Installed as a systemd timer by infra/cloud-init.yaml.
#
# Usage:  scripts/backup-mongo.sh
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[backup $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[backup] ERROR: $*" >&2; }

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

STORAGE_ACCOUNT="$(env_value BACKUP_STORAGE_ACCOUNT)"
CONTAINER="$(env_value BACKUP_CONTAINER)"
CONTAINER="${CONTAINER:-mongo-backups}"
RETENTION_DAYS="$(env_value BACKUP_RETENTION_DAYS)"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"

if [ -z "$STORAGE_ACCOUNT" ]; then
  fail "BACKUP_STORAGE_ACCOUNT is not set; nothing to upload to."
  fail "Set it in Key Vault as BACKUP-STORAGE-ACCOUNT, or disable this timer:"
  fail "  systemctl disable --now librechat-backup.timer"
  exit 1
fi

STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
ARCHIVE_NAME="librechat-${STAMP}.archive.gz"
# Same timestamp as the Mongo archive: that shared stamp is how restore.sh finds
# the vector dump that belongs to a given database dump.
VECTOR_NAME="vectordb-${STAMP}.sql.gz"
# Staged on the data disk rather than /tmp: a full dump can be larger than the
# OS disk's free space, and the data disk is sized for it.
STAGING_DIR="${DATA_DIR}/backups"
ARCHIVE_PATH="${STAGING_DIR}/${ARCHIVE_NAME}"
VECTOR_PATH="${STAGING_DIR}/${VECTOR_NAME}"
POSTGRES_DB="$(env_value POSTGRES_DB)"
POSTGRES_DB="${POSTGRES_DB:-librechat}"
POSTGRES_USER="$(env_value POSTGRES_USER)"
POSTGRES_USER="${POSTGRES_USER:-librechat}"

mkdir -p "$STAGING_DIR"
# The dumps are complete copies of confidential data. Remove them from local
# disk whatever happens, including on failure — the durable copies are in Blob.
trap 'rm -f "$ARCHIVE_PATH" "$VECTOR_PATH"' EXIT


# -----------------------------------------------------------------------------
# 1. Dump.
# -----------------------------------------------------------------------------
# --archive writes a single stream instead of a directory tree, which is what
# makes the result one file that restore.sh can take on stdin.
log "dumping the LibreChat database"
docker compose -f compose.yaml exec -T mongodb \
  mongodump --archive --gzip --db LibreChat > "$ARCHIVE_PATH"

ARCHIVE_BYTES="$(stat -c %s "$ARCHIVE_PATH")"

# A dump of a live instance is tens of megabytes. A dump measured in kilobytes
# means mongodump wrote an error where the data should be, and uploading it
# would quietly replace a good backup with a useless one.
if [ "$ARCHIVE_BYTES" -lt 1048576 ]; then
  fail "the dump is only ${ARCHIVE_BYTES} bytes — that is not a real backup."
  fail "Check that the mongodb container is running and holds data:"
  fail "  docker compose -f compose.yaml exec mongodb mongosh --eval 'db.getMongo().getDBs()'"
  exit 1
fi

log "dump is $(numfmt --to=iec "$ARCHIVE_BYTES")"

# Data only, and only the two tables the RAG API owns. The schema belongs to the
# RAG API, which creates it on startup; restoring data into whatever schema the
# target's RAG API created is what keeps this portable across hosts whose
# database and role names differ. Plain SQL rather than pg_dump's custom format
# so the same file also works with the manual steps in
# docs/modules/migrating-an-existing-install.md.
#
# A failure here does not stop the Mongo upload: a database dump without
# vectors is still worth keeping. The script exits non-zero at the end, so the
# timer shows the failure.
VECTOR_OK=true
log "dumping the vector database"
if docker compose -f compose.yaml exec -T vectordb \
     pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --data-only \
       --table=langchain_pg_collection --table=langchain_pg_embedding \
   | gzip -c > "$VECTOR_PATH"; then
  log "vector dump is $(numfmt --to=iec "$(stat -c %s "$VECTOR_PATH")")"
else
  fail "the vector database dump failed; uploading the MongoDB dump anyway."
  rm -f "$VECTOR_PATH"
  VECTOR_OK=false
fi


# -----------------------------------------------------------------------------
# 2. Upload.
# -----------------------------------------------------------------------------
if ! az account show >/dev/null 2>&1; then
  az login --identity --allow-no-subscriptions --output none
fi

log "uploading $ARCHIVE_NAME to $STORAGE_ACCOUNT/$CONTAINER"
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "$ARCHIVE_NAME" \
  --file "$ARCHIVE_PATH" \
  --auth-mode login \
  --overwrite false \
  --output none

if [ "$VECTOR_OK" = true ]; then
  log "uploading $VECTOR_NAME"
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$VECTOR_NAME" \
    --file "$VECTOR_PATH" \
    --auth-mode login \
    --overwrite false \
    --output none
fi

log "uploaded"


# -----------------------------------------------------------------------------
# 3. Prune old backups.
# -----------------------------------------------------------------------------
# Deleting only blobs whose name matches the pattern this script writes, so a
# misconfigured container shared with something else cannot be emptied by us.
CUTOFF="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
log "removing backups older than $CUTOFF (${RETENTION_DAYS} days)"

old_blobs="$(
  for prefix in librechat- vectordb-; do
    az storage blob list \
      --account-name "$STORAGE_ACCOUNT" \
      --container-name "$CONTAINER" \
      --prefix "$prefix" \
      --auth-mode login \
      --query "[?properties.creationTime < '${CUTOFF}'].name" \
      --output tsv
  done
)"

pruned=0
while IFS= read -r blob; do
  [ -n "$blob" ] || continue
  az storage blob delete \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$blob" \
    --auth-mode login \
    --output none
  pruned=$((pruned + 1))
done <<< "$old_blobs"

log "pruned $pruned old backup(s)"

if [ "$VECTOR_OK" = false ]; then
  fail "finished WITHOUT a vector database dump — see the error above."
  exit 1
fi
log "done"

# -----------------------------------------------------------------------------
# An untested backup is not a backup.
# -----------------------------------------------------------------------------
# Restoring the most recent dump into staging takes about five minutes and is
# the only way to know this file works. docs/modules/backups.md lists it as a
# quarterly task. Please actually do it.
