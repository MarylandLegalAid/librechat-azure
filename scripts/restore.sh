#!/usr/bin/env bash
#
# Restore a MongoDB dump into this instance.
#
# ⚠️  THIS REPLACES THE DATABASE. Every conversation, user, and agent currently
# in this instance is dropped and replaced by the contents of the archive.
#
# It is used for three different jobs, which is deliberate — the procedure that
# runs during a real migration should be the one that has been run dozens of
# times, not a special one written for the occasion:
#
#   - refreshing staging from a copy of production
#   - the cutover itself, when moving to a new host
#   - proving that a nightly backup actually restores
#
# The restore is destructive AND idempotent, which is what makes a rehearsal
# repeatable: running it again cleanly discards the previous attempt, including
# any test data created in between. Rehearse as many times as you like.
#
# What it does NOT restore: uploaded files. Under FILE_STORAGE=disk those live
# on the data disk and are copied separately — see
# docs/modules/migrating-an-existing-install.md. Restoring the database without
# the files leaves attachments that appear in conversations but will not open.
#
# Usage:
#   scripts/restore.sh /path/to/librechat.archive.gz
#   scripts/restore.sh --from-blob librechat-2026-08-01T03-00-00Z.archive.gz
#   scripts/restore.sh --from-blob latest
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[restore $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[restore] ERROR: $*" >&2; }

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

ARCHIVE_PATH=""
BLOB_NAME=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --from-blob) BLOB_NAME="$2"; shift 2 ;;
    --yes|-y)    ASSUME_YES=true; shift ;;
    -h|--help)   usage ;;
    -*)          fail "unknown argument: $1"; usage ;;
    *)           ARCHIVE_PATH="$1"; shift ;;
  esac
done

[ -n "$ARCHIVE_PATH" ] || [ -n "$BLOB_NAME" ] || usage

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"
DOWNLOADED=""


# -----------------------------------------------------------------------------
# 1. Get the archive.
# -----------------------------------------------------------------------------
if [ -n "$BLOB_NAME" ]; then
  STORAGE_ACCOUNT="$(env_value BACKUP_STORAGE_ACCOUNT)"
  CONTAINER="$(env_value BACKUP_CONTAINER)"
  CONTAINER="${CONTAINER:-mongo-backups}"

  if [ -z "$STORAGE_ACCOUNT" ]; then
    fail "BACKUP_STORAGE_ACCOUNT is not set, so --from-blob has nowhere to read from."
    exit 1
  fi

  if ! az account show >/dev/null 2>&1; then
    az login --identity --allow-no-subscriptions --output none
  fi

  if [ "$BLOB_NAME" = "latest" ]; then
    log "finding the most recent backup in $STORAGE_ACCOUNT/$CONTAINER"
    BLOB_NAME="$(
      az storage blob list \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER" \
        --prefix "librechat-" \
        --auth-mode login \
        --query "sort_by([], &properties.creationTime)[-1].name" \
        --output tsv
    )"
    [ -n "$BLOB_NAME" ] && [ "$BLOB_NAME" != "None" ] || { fail "no backups found."; exit 1; }
    log "most recent is $BLOB_NAME"
  fi

  mkdir -p "${DATA_DIR}/backups"
  ARCHIVE_PATH="${DATA_DIR}/backups/${BLOB_NAME}"
  DOWNLOADED="$ARCHIVE_PATH"

  log "downloading $BLOB_NAME"
  az storage blob download \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$ARCHIVE_PATH" \
    --auth-mode login \
    --output none
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
  fail "no such file: $ARCHIVE_PATH"
  exit 1
fi

ARCHIVE_BYTES="$(stat -c %s "$ARCHIVE_PATH")"
if [ "$ARCHIVE_BYTES" -lt 1048576 ]; then
  fail "$ARCHIVE_PATH is only ${ARCHIVE_BYTES} bytes."
  fail "That is too small to be a real dump — restoring it would wipe this"
  fail "instance and put almost nothing back. Refusing."
  exit 1
fi

log "archive: $ARCHIVE_PATH ($(numfmt --to=iec "$ARCHIVE_BYTES"))"


# -----------------------------------------------------------------------------
# 2. Confirm, unless told not to ask.
# -----------------------------------------------------------------------------
if [ "$ASSUME_YES" = false ]; then
  CURRENT_USERS="$(
    docker compose -f compose.yaml exec -T mongodb \
      mongosh LibreChat --quiet --eval 'db.users.countDocuments()' 2>/dev/null || echo "unknown"
  )"
  echo ""
  echo "  About to DROP and replace the LibreChat database on this host."
  echo "  It currently holds ${CURRENT_USERS} user account(s)."
  echo "  Everything in it will be gone. This cannot be undone."
  echo ""
  read -r -p "  Type 'restore' to continue: " reply
  [ "$reply" = "restore" ] || { log "cancelled"; exit 1; }
fi


# -----------------------------------------------------------------------------
# 3. Stop the application, but not the database.
# -----------------------------------------------------------------------------
# Restoring underneath a running application produces cache and session state
# that refers to documents which no longer exist. Mongo itself must stay up —
# it is what mongorestore talks to.
log "stopping the application"
docker compose -f compose.yaml stop api admin-panel || true


# -----------------------------------------------------------------------------
# 4. Restore.
# -----------------------------------------------------------------------------
# --drop is what makes this re-runnable: each collection is dropped immediately
# before being rewritten, so a previous rehearsal leaves nothing behind.
log "restoring (this takes a few minutes)"
docker compose -f compose.yaml exec -T mongodb \
  mongorestore --archive --gzip --drop < "$ARCHIVE_PATH"


# -----------------------------------------------------------------------------
# 5. Start the application again.
# -----------------------------------------------------------------------------
log "starting the application"
docker compose -f compose.yaml start api admin-panel

[ -n "$DOWNLOADED" ] && rm -f "$DOWNLOADED"

log "restore complete"
echo ""
echo "  Next:"
echo "    - Meilisearch reindexes from MongoDB on its own. Search results will"
echo "      be incomplete until it finishes; check by searching for a phrase you"
echo "      know exists in an old conversation."
echo "    - If this was a migration, copy the uploaded files across too, or"
echo "      attachments will appear in conversations but fail to open."
echo "    - If the source instance used different models, run"
echo "      scripts/migrate-agent-models.js --dry-run before anyone signs in."
