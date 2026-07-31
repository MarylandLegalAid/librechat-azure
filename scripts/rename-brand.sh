#!/usr/bin/env bash
#
# Rename the versioned wordmark on agents: MLAGPT 4 -> MLAGPT 4.1.
#
#     scripts/rename-brand.sh              # dry run — changes nothing
#     scripts/rename-brand.sh --dry-run    # the same thing, said out loud
#     scripts/rename-brand.sh --apply      # actually write
#
# RUN THIS AFTER EVERY RESTORE, alongside the other two agent fixups. The agents
# live in Mongo, not in this repository, so a restore from old production brings
# the previous release name straight back. Expect 2 agents changed / 4 field
# writes on the 2026-08-01 data.
#
# The wordmark lives in four places. This script owns exactly one of them:
#
#   HERE  agents.name / .description / .instructions   database — needs this
#   git   librechat.yaml modalTitle, customWelcome     deployed with the repo
#   vault APP-TITLE                                    browser tab and header
#   vault CUSTOM-FOOTER                                footer disclaimer
#
# The three outside the database survive a restore on their own and need no
# post-restore step. A Key Vault change does need `deploy.sh --force`, because
# it leaves git untouched and an ordinary deploy would find nothing to do.
#
# What it deliberately does not change:
#
#   - versions[] snapshots. John's call on 2026-07-31 — a snapshot is a record
#     of what an agent was. The script counts them and says so, because
#     restoring one of those versions from the UI brings the old name back and
#     that should not be a surprise.
#   - Users' own words. 7 messages and 5 conversation titles mention the old
#     name; rewriting those would be editing real conversation history.
#   - The unversioned "MLAGPT" in the user agreement, which is the product in
#     general rather than a release.
#
# Safe to run repeatedly. After a successful --apply, running it again reports
# zero changes — and the apply path asserts that property rather than trusting
# it.
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
    *) echo "rename-brand.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"

# Interactive prompts and `az ssh vm -- '<cmd>'` do not mix: there is no TTY, so
# `read` gets EOF and this cancels cleanly before any write. Pipe the token in
# when running it that way:  echo apply | sudo ./scripts/rename-brand.sh --apply
if [ "$APPLY" = true ]; then
  echo ""
  echo "  About to RENAME agent names, descriptions and instructions."
  echo "  Run without --apply first and read what it proposes to change."
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
docker compose -f compose.yaml exec -T mongodb mongosh LibreChat --quiet \
  --eval "globalThis.APPLY = ${APPLY}" \
  --file /scripts/rename-brand.js \
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
CHANGELOG_FILE="${CHANGELOG_DIR}/brand-rename-${STAMP}-${SUFFIX}.json"

if grep -q '===CHANGELOG-JSON-BEGIN===' "$OUTPUT_FILE"; then
  mkdir -p "$CHANGELOG_DIR"
  sed -n '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/p' "$OUTPUT_FILE" \
    | sed '1d;$d' > "$CHANGELOG_FILE"
  echo ""
  echo "  Audit trail: $CHANGELOG_FILE"
fi

exit "$STATUS"
