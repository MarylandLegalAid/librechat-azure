#!/usr/bin/env bash
#
# Move every LibreChat Agent onto an approved model.
#
#     scripts/migrate-agent-models.sh              # dry run — changes nothing
#     scripts/migrate-agent-models.sh --dry-run    # the same thing, said out loud
#     scripts/migrate-agent-models.sh --apply      # actually write
#
# Dry run is the default because the interesting failure mode of this script is
# not "it crashed", it is "it did something reasonable-looking to the wrong
# agents". Read the output. Compare the totals against what you expect. Only
# then apply.
#
# Safe to run repeatedly. After a successful --apply, running it again reports
# zero changes — every agent is already on an approved model, and the rule is to
# leave those alone.
#
# What it changes:
#   - agent.model and agent.provider
#   - the same two fields in EVERY entry of agent.versions[]
#
# The version history matters more than it looks like it should. LibreChat lets
# a user revert an agent to an earlier version, and an untouched snapshot brings
# a retired model back with it. One agent on production carried 46 versions.
#
# What it deliberately does not change: conversations and messages. Those record
# which model actually produced each historical response. Rewriting them would
# be falsifying a record, not fixing a configuration.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAP_FILE="$REPO_ROOT/scripts/model-map.json"
APPLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=true;  shift ;;
    --dry-run) APPLY=false; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "migrate-agent-models.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"

[ -f "$MAP_FILE" ] || { echo "missing $MAP_FILE" >&2; exit 1; }

# model-map.json is valid JavaScript as well as valid JSON, so it can be handed
# straight to mongosh as an object literal. mongosh has no file system access of
# its own, so this is how the map gets in.
MAP_JSON="$(cat "$MAP_FILE")"

if [ "$APPLY" = true ]; then
  echo ""
  echo "  About to REWRITE agent documents in the LibreChat database."
  echo "  Run without --apply first if you have not already read the plan."
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
docker compose -f compose.yaml exec -T mongodb mongosh LibreChat --quiet \
  --eval "globalThis.MODEL_MAP_RAW = ${MAP_JSON}" \
  --eval "globalThis.APPLY = ${APPLY}" \
  --file /scripts/migrate-agent-models.js \
  2>&1 | tee "$OUTPUT_FILE"
STATUS=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------
# Keep the audit trail.
# ---------------------------------------------------------------------------
# On the data disk, so it is covered by Azure Backup rather than living in a
# terminal scrollback that closes at the end of the day. A dry run is recorded
# too — the record of what you decided not to do is part of the story.
CHANGELOG_DIR="${DATA_DIR}/migrations"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
SUFFIX=$([ "$APPLY" = true ] && echo "apply" || echo "dry-run")
CHANGELOG_FILE="${CHANGELOG_DIR}/agent-models-${STAMP}-${SUFFIX}.json"

if grep -q '===CHANGELOG-JSON-BEGIN===' "$OUTPUT_FILE"; then
  mkdir -p "$CHANGELOG_DIR"
  sed -n '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/p' "$OUTPUT_FILE" \
    | sed '1d;$d' > "$CHANGELOG_FILE"
  echo ""
  echo "  Audit trail: $CHANGELOG_FILE"
fi

exit "$STATUS"
