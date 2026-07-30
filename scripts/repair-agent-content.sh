#!/usr/bin/env bash
#
# Reapply agent content that a restore cannot reproduce.
#
#     scripts/repair-agent-content.sh              # dry run — changes nothing
#     scripts/repair-agent-content.sh --dry-run    # the same thing, said out loud
#     scripts/repair-agent-content.sh --apply      # actually write
#
# RUN THIS AFTER scripts/migrate-agent-models.sh, on every restore.
#
# The model migration fixes which model an agent points at, which is derivable
# from a rule. This fixes the agent's own CONTENT — its instructions and its tool
# selection — which is not derivable from anything, because it is prose somebody
# wrote. scripts/agent-content.json is the recorded copy.
#
# Why it is needed at all: legalserver-mcp v3.0.0 renamed its whole tool surface,
# so every agent restored from old production points at tools that no longer
# exist. Two of them had already been rewritten against the new surface on the
# Render deployment; that work was recovered from Render's nightly dump on
# 2026-07-30 and lives in the data file so a restore can reapply it instead of
# somebody redoing it by hand mid-cutover.
#
# What it changes:
#   - agent.instructions and agent.tools, for the agents named in the data file
#   - dead tool names removed from EVERY agent's tools[] and from every
#     versions[] snapshot
#
# The version history matters for the same reason it does in the model
# migration: a user can revert an agent to an earlier version, and an untouched
# snapshot brings a dead tool reference back with it.
#
# What it deliberately does not change: instructions inside versions[]. A
# dangling tool name is a broken pointer and gets fixed; the prose an author
# wrote in March is a record, and rewriting it would be falsifying one.
#
# Safe to run repeatedly. After a successful --apply, running it again reports
# zero changes.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTENT_FILE="$REPO_ROOT/scripts/agent-content.json"
APPLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=true;  shift ;;
    --dry-run) APPLY=false; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "repair-agent-content.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"

[ -f "$CONTENT_FILE" ] || { echo "missing $CONTENT_FILE" >&2; exit 1; }

# agent-content.json is valid JavaScript as well as valid JSON, so it can be
# handed straight to mongosh as an object literal. mongosh has no file system
# access of its own, so this is how the content gets in.
CONTENT_JSON="$(cat "$CONTENT_FILE")"

if [ "$APPLY" = true ]; then
  echo ""
  echo "  About to REWRITE agent instructions and tool selections."
  echo "  Run without --apply first and read what it proposes to change."
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
docker compose -f compose.yaml exec -T mongodb mongosh LibreChat --quiet \
  --eval "globalThis.AGENT_CONTENT_RAW = ${CONTENT_JSON}" \
  --eval "globalThis.APPLY = ${APPLY}" \
  --file /scripts/repair-agent-content.js \
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
CHANGELOG_FILE="${CHANGELOG_DIR}/agent-content-${STAMP}-${SUFFIX}.json"

if grep -q '===CHANGELOG-JSON-BEGIN===' "$OUTPUT_FILE"; then
  mkdir -p "$CHANGELOG_DIR"
  sed -n '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/p' "$OUTPUT_FILE" \
    | sed '1d;$d' > "$CHANGELOG_FILE"
  echo ""
  echo "  Audit trail: $CHANGELOG_FILE"
fi

exit "$STATUS"
