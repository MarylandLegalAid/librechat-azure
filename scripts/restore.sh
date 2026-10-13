#!/usr/bin/env bash
#
# Restore a backup into this instance: MongoDB, the vector database, and a
# rebuilt search index.
#
# ⚠️  THIS REPLACES THE DATABASE. Every conversation, user, agent and document
# embedding currently in this instance is dropped and replaced by the contents
# of the backup.
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
# A LibreChat backup is three stores, and each fails SILENTLY if left out:
#
#   MongoDB      users, conversations, agents, file records
#   pgvector     what the uploaded documents say. Without it, document chat
#                answers without consulting the documents — no error.
#   Meilisearch  conversation search. Derived from MongoDB, but a restored dump
#                tells LibreChat the index is already built, so it never
#                rebuilds — no error.
#
# This script restores the first two and makes LibreChat rebuild the third,
# then checks all three before it calls the restore good.
#
# What it does NOT restore: uploaded files. Under FILE_STORAGE=disk those live
# on the data disk and are copied separately — see
# docs/modules/migrating-an-existing-install.md. Restoring the database without
# the files leaves attachments that appear in conversations but will not open.
#
# Usage:
#   scripts/restore.sh --from-blob latest
#   scripts/restore.sh --from-blob librechat-2026-08-01T03-00-00Z.archive.gz
#   scripts/restore.sh /path/to/librechat.archive.gz --vectordb /path/to/vectordb.sql.gz
#
# With --from-blob, the vector dump taken in the same backup run is found by its
# timestamp. A backup from before vector dumps existed has none: pass
# --skip-vectordb to restore it anyway, knowing document chat will not work for
# the documents in it.
#
# Options:
#   --vectordb PATH   the vector dump to restore with a local archive
#   --skip-vectordb   restore MongoDB only and leave the vector database alone
#   --yes, -y         do not ask for confirmation
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
VECTOR_PATH=""
SKIP_VECTORDB=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --from-blob)     BLOB_NAME="$2"; shift 2 ;;
    --vectordb)      VECTOR_PATH="$2"; shift 2 ;;
    --skip-vectordb) SKIP_VECTORDB=true; shift ;;
    --yes|-y)        ASSUME_YES=true; shift ;;
    -h|--help)       usage ;;
    -*)              fail "unknown argument: $1"; usage ;;
    *)               ARCHIVE_PATH="$1"; shift ;;
  esac
done

[ -n "$ARCHIVE_PATH" ] || [ -n "$BLOB_NAME" ] || usage

if [ "$SKIP_VECTORDB" = true ] && [ -n "$VECTOR_PATH" ]; then
  fail "--vectordb and --skip-vectordb contradict each other."
  exit 2
fi

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"
POSTGRES_DB="$(env_value POSTGRES_DB)"
POSTGRES_DB="${POSTGRES_DB:-librechat}"
POSTGRES_USER="$(env_value POSTGRES_USER)"
POSTGRES_USER="${POSTGRES_USER:-librechat}"
HEALTH_URL="http://127.0.0.1:3080/health"
# How long to wait for Meilisearch to catch up before calling search broken. A
# production-sized restore takes a couple of minutes, and the count sits still
# for a while before it jumps.
SEARCH_WAIT_SECONDS="${SEARCH_WAIT_SECONDS:-900}"

COMPOSE=(docker compose -f compose.yaml)
DOWNLOADED=()
# Downloaded dumps are complete copies of confidential data. Remove them however
# this script ends.
cleanup() { [ "${#DOWNLOADED[@]}" -eq 0 ] || rm -f "${DOWNLOADED[@]}"; }
trap cleanup EXIT

mongo_eval() {
  "${COMPOSE[@]}" exec -T mongodb mongosh LibreChat --quiet --eval "$1"
}

psql_value() {
  "${COMPOSE[@]}" exec -T vectordb \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "$1"
}

# Only documents LibreChat would index: not temporary, not expired.
RETENTION_FILTER='{$or:[{isTemporary:false,expiredAt:null},{isTemporary:false,expiredAt:{$gt:new Date()}},{isTemporary:null,expiredAt:null}]}'


# -----------------------------------------------------------------------------
# 1. Get the archives. Everything that can fail is checked before anything is
#    destroyed.
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

  download() {
    local name="$1" dest="$2"
    DOWNLOADED+=("$dest")
    log "downloading $name"
    az storage blob download \
      --account-name "$STORAGE_ACCOUNT" \
      --container-name "$CONTAINER" \
      --name "$name" \
      --file "$dest" \
      --auth-mode login \
      --output none
  }

  ARCHIVE_PATH="${DATA_DIR}/backups/${BLOB_NAME}"
  download "$BLOB_NAME" "$ARCHIVE_PATH"

  if [ "$SKIP_VECTORDB" = false ]; then
    # backup-mongo.sh names both dumps with the same timestamp.
    stamp="${BLOB_NAME#librechat-}"
    stamp="${stamp%.archive.gz}"
    VECTOR_BLOB="vectordb-${stamp}.sql.gz"
    exists="$(
      az storage blob exists \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER" \
        --name "$VECTOR_BLOB" \
        --auth-mode login \
        --query exists --output tsv
    )"
    if [ "$exists" != "true" ]; then
      fail "there is no vector dump ($VECTOR_BLOB) from the same backup run."
      fail "Restoring the database without it leaves document chat answering"
      fail "without consulting the documents, with no error. If that is"
      fail "acceptable (for example, a backup from before vector dumps existed),"
      fail "re-run with --skip-vectordb."
      exit 1
    fi
    VECTOR_PATH="${DATA_DIR}/backups/${VECTOR_BLOB}"
    download "$VECTOR_BLOB" "$VECTOR_PATH"
  fi
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
log "database archive: $ARCHIVE_PATH ($(numfmt --to=iec "$ARCHIVE_BYTES"))"

EXPECTED_EMBEDDINGS=""
if [ "$SKIP_VECTORDB" = false ]; then
  if [ -z "$VECTOR_PATH" ]; then
    fail "no vector dump given. Pass --vectordb PATH, or --skip-vectordb to"
    fail "restore the database alone, knowing document chat will then answer"
    fail "without consulting the documents in this backup."
    exit 1
  fi
  if [ ! -f "$VECTOR_PATH" ] || ! gzip -t "$VECTOR_PATH" 2>/dev/null; then
    fail "$VECTOR_PATH is missing or is not a valid gzip file."
    exit 1
  fi
  # Count the rows in the dump now: it is what the restored table must hold.
  EXPECTED_EMBEDDINGS="$(
    zcat "$VECTOR_PATH" | awk '
      /^COPY public\.langchain_pg_embedding / { inside = 1; next }
      inside && /^\\\.$/                      { inside = 0; next }
      inside                                  { n++ }
      END                                     { print n + 0 }'
  )"
  log "vector dump: $VECTOR_PATH (${EXPECTED_EMBEDDINGS} embeddings)"

  # The RAG API creates its tables on first start. A data-only dump needs them.
  if [ "$(psql_value "SELECT to_regclass('public.langchain_pg_embedding') IS NOT NULL")" != "t" ]; then
    fail "the vector database has no langchain_pg_embedding table yet. Start the"
    fail "stack once so the RAG API creates its schema, then run this again."
    exit 1
  fi
  TARGET_DIMS="$(psql_value "SELECT string_agg(DISTINCT vector_dims(embedding)::text, ',') FROM langchain_pg_embedding")"
fi


# -----------------------------------------------------------------------------
# 2. Confirm, unless told not to ask.
# -----------------------------------------------------------------------------
if [ "$ASSUME_YES" = false ]; then
  CURRENT_USERS="$(mongo_eval 'db.users.countDocuments()' 2>/dev/null || echo "unknown")"
  echo ""
  echo "  About to DROP and replace the LibreChat database on this host."
  echo "  It currently holds ${CURRENT_USERS} user account(s)."
  if [ "$SKIP_VECTORDB" = false ]; then
    echo "  The document embeddings will be replaced too."
  else
    echo "  The vector database will be LEFT AS IT IS (--skip-vectordb)."
  fi
  echo "  Everything replaced will be gone. This cannot be undone."
  echo ""
  read -r -p "  Type 'restore' to continue: " reply
  [ "$reply" = "restore" ] || { log "cancelled"; exit 1; }
fi


# -----------------------------------------------------------------------------
# 3. Stop the applications, but not the data stores.
# -----------------------------------------------------------------------------
# Restoring underneath a running application produces cache and session state
# that refers to documents which no longer exist. The data stores must stay up —
# they are what the restore talks to.
log "stopping the application"
"${COMPOSE[@]}" stop api admin-panel rag_api || true


# -----------------------------------------------------------------------------
# 4. MongoDB.
# -----------------------------------------------------------------------------
# --drop is what makes this re-runnable: each collection is dropped immediately
# before being rewritten, so a previous rehearsal leaves nothing behind.
log "restoring MongoDB (this takes a few minutes)"
"${COMPOSE[@]}" exec -T mongodb \
  mongorestore --archive --gzip --drop < "$ARCHIVE_PATH"


# -----------------------------------------------------------------------------
# 5. Search: make LibreChat rebuild it from what was just restored.
# -----------------------------------------------------------------------------
# Two parts. Clearing the flags is what makes indexSync rebuild at the next api
# start (see the script for why). Emptying the indexes removes entries for
# conversations that existed here before the restore and no longer do.
#
# The indexes are emptied, not deleted: LibreChat applies the `user` filter
# setting only to an index that already exists, so a deleted index would come
# back without it.
log "resetting the search index"
"${COMPOSE[@]}" exec -T mongodb \
  mongosh LibreChat --quiet --file /scripts/reset-meili-flags.js
# Single quotes on purpose: the key is expanded inside the container, so it
# never appears on this host's command line.
# shellcheck disable=SC2016
"${COMPOSE[@]}" exec -T meilisearch sh -c '
  for index in convos messages; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      -H "Authorization: Bearer $MEILI_MASTER_KEY" \
      "http://127.0.0.1:7700/indexes/$index/documents")
    echo "  $index: emptied (HTTP $code; 404 means it did not exist yet)"
  done'


# -----------------------------------------------------------------------------
# 6. The vector database.
# -----------------------------------------------------------------------------
# One transaction: the existing embeddings are removed and the dump's loaded
# together, or not at all. A failure halfway leaves the previous contents.
if [ "$SKIP_VECTORDB" = false ]; then
  log "restoring the vector database"
  {
    echo "TRUNCATE langchain_pg_embedding, langchain_pg_collection CASCADE;"
    zcat "$VECTOR_PATH"
  } | "${COMPOSE[@]}" exec -T vectordb \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -v ON_ERROR_STOP=1 --single-transaction \
        >/dev/null   # the dump's preamble prints a set_config result; errors still reach stderr
fi


# -----------------------------------------------------------------------------
# 7. Start the applications again.
# -----------------------------------------------------------------------------
log "starting the application"
"${COMPOSE[@]}" start rag_api api admin-panel


# -----------------------------------------------------------------------------
# 8. Verify. A restore that "worked" can still be missing search or documents,
#    and neither reports an error on its own.
# -----------------------------------------------------------------------------
PROBLEMS=0
problem() { fail "$*"; PROBLEMS=$((PROBLEMS + 1)); }

log "waiting for the application to answer"
healthy=false
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "$HEALTH_URL" 2>/dev/null; then healthy=true; break; fi
  sleep 3
done
[ "$healthy" = true ] || problem "the application did not become healthy at $HEALTH_URL"

# Documents: the restored table must hold exactly what the dump held.
if [ "$SKIP_VECTORDB" = false ]; then
  restored="$(psql_value "SELECT count(*) FROM langchain_pg_embedding")"
  dims="$(psql_value "SELECT string_agg(DISTINCT vector_dims(embedding)::text, ',') FROM langchain_pg_embedding")"
  if [ "$restored" != "$EXPECTED_EMBEDDINGS" ]; then
    problem "vector database holds $restored embeddings; the dump had $EXPECTED_EMBEDDINGS"
  else
    log "  documents: $restored embeddings restored, as in the dump"
  fi
  case "$dims" in
    *,*) problem "embeddings have mixed dimensions ($dims): the embedding model changed at some point" ;;
  esac
  if [ -n "$TARGET_DIMS" ] && [ -n "$dims" ] && [ "$TARGET_DIMS" != "$dims" ]; then
    problem "this host's embeddings were ${TARGET_DIMS}-dimensional and the backup's are ${dims}."
    problem "The embedding model differs between them: document chat will return nonsense."
    problem "See docs/modules/models.md before anyone uses document chat here."
  fi
  # For information. Production does not match perfectly either: a file whose
  # embedding failed can still be marked embedded. Compare with the source.
  mongo_files="$(mongo_eval 'db.files.countDocuments({embedded:true})')"
  pg_files="$(psql_value "SELECT count(DISTINCT cmetadata->>'file_id') FROM langchain_pg_embedding")"
  log "  documents: MongoDB marks $mongo_files files embedded; the vector database has $pg_files"
else
  log "  documents: not restored (--skip-vectordb)"
fi

# Search: wait for Meilisearch to hold about as many conversations as MongoDB.
expected_convos="$(mongo_eval "db.conversations.countDocuments(${RETENTION_FILTER})")"
log "waiting for search to rebuild ($expected_convos conversations; up to $((SEARCH_WAIT_SECONDS / 60)) min)"
indexed=0
deadline=$((SECONDS + SEARCH_WAIT_SECONDS))
while :; do
  # shellcheck disable=SC2016
  indexed="$(
    "${COMPOSE[@]}" exec -T meilisearch sh -c \
      'curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://127.0.0.1:7700/indexes/convos/stats' \
    | sed -n 's/.*"numberOfDocuments":\([0-9]*\).*/\1/p'
  )"
  indexed="${indexed:-0}"
  # Within 2%: Meilisearch collapses duplicates, and production itself runs a
  # few dozen short of MongoDB. A gap of thousands is the failure this catches.
  if [ $((indexed * 100)) -ge $((expected_convos * 98)) ]; then break; fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 15
done
if [ $((indexed * 100)) -ge $((expected_convos * 98)) ]; then
  log "  search: $indexed of $expected_convos conversations indexed"
else
  problem "search holds $indexed of $expected_convos conversations after $((SEARCH_WAIT_SECONDS / 60)) minutes"
fi

echo ""
if [ "$PROBLEMS" -gt 0 ]; then
  fail "the restore ran, but $PROBLEMS check(s) above failed. Do not treat this instance as good."
  exit 1
fi

log "restore complete and verified"
echo ""
echo "  Still to do by hand:"
echo "    - Sign in, open an old conversation, and search for a phrase you know"
echo "      exists. Ask a document-chat question about an old file."
echo "    - If this was a migration, copy the uploaded files across too, or"
echo "      attachments will appear in conversations but fail to open."
echo "    - Re-run every database repair script (agent models, and anything"
echo "      else you keep for after a restore). See"
echo "      docs/modules/migrating-an-existing-install.md, step 7."
