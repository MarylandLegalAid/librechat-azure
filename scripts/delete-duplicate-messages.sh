#!/usr/bin/env bash
#
# Delete the unfinished placeholder copy of each duplicated assistant message.
#
#     scripts/delete-duplicate-messages.sh              # dry run — changes nothing
#     scripts/delete-duplicate-messages.sh --dry-run    # the same thing, said out loud
#     scripts/delete-duplicate-messages.sh --apply      # actually delete
#
# RUN THIS BEFORE v0.8.8's tenant-index migration, with the writers stopped.
# See docs/modules/upgrading.md ("Releases with an offline database migration").
#
# v0.8.7 sometimes saves a streaming reply twice: an `unfinished` placeholder
# and the finished reply, under the same messageId. The migration builds a
# unique index on { messageId, user, tenantId } and fails on the first pair.
# This keeps the finished copy, which is what users already see by default, and
# deletes the placeholder. lib/duplicate-message-cleanup.js has the full story.
#
# There is no --revert. The deleted copies are recoverable only from the backup
# taken at the start of the upgrade. The audit trail records which documents
# went (ids, dates, sizes) but not their content, so a restore can be targeted.
#
# A key it cannot resolve (no finished copy, or two) is left untouched and
# reported, and the script exits non-zero: the migration would fail on it too,
# and a human has to look.
#
# Safe to run repeatedly. After a successful --apply, running it again reports
# zero duplicate keys.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APPLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=true;  shift ;;
    --dry-run) APPLY=false; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "delete-duplicate-messages.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"

if [ "$APPLY" = true ]; then
  echo ""
  echo "  About to DELETE message documents. The only way back is a restore."
  echo "  Run without --apply first and read what it proposes to delete."
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
docker compose -f compose.yaml exec -T mongodb mongosh LibreChat --quiet \
  --eval "globalThis.APPLY = ${APPLY}" \
  --file /scripts/delete-duplicate-messages.js \
  2>&1 | tee "$OUTPUT_FILE"
STATUS=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------
# Keep the audit trail.
# ---------------------------------------------------------------------------
# On the data disk, next to the other migration records. A dry run is recorded
# too: it is the list a restore would need if the apply is ever questioned.
CHANGELOG_DIR="${DATA_DIR}/migrations"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
SUFFIX=$([ "$APPLY" = true ] && echo "apply" || echo "dry-run")
CHANGELOG_FILE="${CHANGELOG_DIR}/duplicate-messages-${STAMP}-${SUFFIX}.json"

if grep -q '===CHANGELOG-JSON-BEGIN===' "$OUTPUT_FILE"; then
  mkdir -p "$CHANGELOG_DIR"
  sed -n '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/p' "$OUTPUT_FILE" \
    | sed '1d;$d' > "$CHANGELOG_FILE"
  echo ""
  echo "  Audit trail: $CHANGELOG_FILE"
fi

exit "$STATUS"
