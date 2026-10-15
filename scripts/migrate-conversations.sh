#!/usr/bin/env bash
#
# Move conversations on retired models onto their successors.
#
#     scripts/migrate-conversations.sh                       # dry run — changes nothing
#     scripts/migrate-conversations.sh --apply               # actually write
#     scripts/migrate-conversations.sh --revert FILE         # dry run of an undo
#     scripts/migrate-conversations.sh --revert FILE --apply # undo an --apply run
#
# A conversation stores the endpoint and model its NEXT turn will use. When a
# model is retired, conversations still pointing at it either fail when someone
# continues them, or quietly keep using the retired model. This moves that
# next-turn model to the same-tier successor in scripts/conversation-map.json.
#
# What it changes: the conversation document's endpoint, model, and whatever
# else the map's target lists (endpointType, spec, useResponsesApi,
# maxContextTokens) — the fields a conversation the UI created on that model
# would have.
#
# The same run moves saved presets (they carry the same fields, so the same
# targets apply) and favorites pinned in the model selector: { endpoint, model }
# through the same table, { spec } through the map's `specs`. Agent favorites
# are never touched. Both are in the audit trail and --revert.
#
# What it never changes: messages. Each records which model actually wrote it.
# Nor updatedAt, so nobody's sidebar reorders.
#
# Dry run is the default. Read the totals and compare them with what you expect
# before applying. Safe to run repeatedly: after an apply, the next dry run
# reports nothing to move. Every run, dry or not, leaves an audit trail on the
# data disk; an --apply trail records every changed field's old value, and
# --revert FILE puts them back for any conversation still where the run left it.
#
# Conversation titles appear nowhere in the output or the audit trail. They are
# user content and can name clients.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAP_FILE="$REPO_ROOT/scripts/conversation-map.json"
APPLY=false
REVERT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=true;  shift ;;
    --dry-run) APPLY=false; shift ;;
    --revert)  REVERT_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "migrate-conversations.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"
COMPOSE=(docker compose -f compose.yaml)

[ -f "$MAP_FILE" ] || { echo "missing $MAP_FILE" >&2; exit 1; }
if [ -n "$REVERT_FILE" ] && [ ! -f "$REVERT_FILE" ]; then
  echo "no such audit trail: $REVERT_FILE" >&2
  exit 1
fi

if [ "$APPLY" = true ]; then
  echo ""
  if [ -n "$REVERT_FILE" ]; then
    echo "  About to RESTORE conversation documents from $REVERT_FILE."
  else
    echo "  About to REWRITE conversation documents in the LibreChat database."
    echo "  Run without --apply first if you have not already read the dry run."
  fi
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

OUTPUT_FILE="$(mktemp)"
CONTAINER_REVERT="/tmp/conversation-revert.json"
cleanup() {
  rm -f "$OUTPUT_FILE"
  if [ -n "$REVERT_FILE" ]; then
    "${COMPOSE[@]}" exec -T mongodb rm -f "$CONTAINER_REVERT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# The map goes in as an object literal (valid JSON is valid JavaScript), like
# migrate-agent-models.sh. An audit trail can run to megabytes, too large for a
# command line, so a revert copies the file into the container instead.
EVALS=(--eval "void (globalThis.CONVERSATION_MAP_RAW = $(cat "$MAP_FILE"))"
       --eval "void (globalThis.APPLY = ${APPLY})")
if [ -n "$REVERT_FILE" ]; then
  "${COMPOSE[@]}" exec -T mongodb sh -c "cat > $CONTAINER_REVERT" < "$REVERT_FILE"
  EVALS+=(--eval "void (globalThis.REVERT_FILE = '$CONTAINER_REVERT')")
fi

set +e
"${COMPOSE[@]}" exec -T mongodb mongosh LibreChat --quiet \
  "${EVALS[@]}" \
  --file /scripts/migrate-conversations.js \
  | sed '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/!b;w '"$OUTPUT_FILE"'
d'
STATUS=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------
# Keep the audit trail, on the data disk where Azure Backup covers it.
# ---------------------------------------------------------------------------
# Printed to the screen only as a path: an apply trail lists every moved
# conversation, which is far too long to read and is what --revert consumes.
CHANGELOG_DIR="${DATA_DIR}/migrations"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
case "${REVERT_FILE:+revert}-${APPLY}" in
  revert-true)  SUFFIX="revert" ;;
  revert-false) SUFFIX="revert-dry-run" ;;
  -true)        SUFFIX="apply" ;;
  *)            SUFFIX="dry-run" ;;
esac
CHANGELOG_FILE="${CHANGELOG_DIR}/conversations-${STAMP}-${SUFFIX}.json"

if grep -q '===CHANGELOG-JSON-BEGIN===' "$OUTPUT_FILE"; then
  mkdir -p "$CHANGELOG_DIR"
  sed '1d;$d' "$OUTPUT_FILE" > "$CHANGELOG_FILE"
  chmod 600 "$CHANGELOG_FILE"
  echo "  Audit trail: $CHANGELOG_FILE"
  if [ "$SUFFIX" = "apply" ]; then
    echo "  To undo:     scripts/migrate-conversations.sh --revert $CHANGELOG_FILE --apply"
  fi
fi

exit "$STATUS"
