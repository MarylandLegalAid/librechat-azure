#!/usr/bin/env bash
#
# Remove agent knowledge files whose S3 object no longer exists.
#
#     scripts/remove-dead-agent-files.sh                        # dry run — changes nothing
#     scripts/remove-dead-agent-files.sh --apply                # actually write
#     scripts/remove-dead-agent-files.sh --revert FILE          # dry run of an undo
#     scripts/remove-dead-agent-files.sh --revert FILE --apply  # undo an --apply run
#
# RUN THIS IN THE v0.8.8 UPGRADE WINDOW, with the writers stopped, before
# v0.8.8 starts. See docs/modules/upgrading.md (step 4c).
#
# v0.8.8 re-embeds an agent's pre-v0.8.8 knowledge files on first use, reading
# each one from storage. If a file cannot be read, the agent's file search
# fails on every turn. v0.8.7 still searches the old vectors, so this matters
# only from the upgrade on. lib/dead-agent-file-cleanup.js has the full story.
#
# A file is removed only if its record says `source: s3` AND a HEAD of the
# object, with the deployment's own AWS settings, returns 404. Any other answer
# (403, a timeout, no credentials) stops the run before anything changes.
# Removed from: every tool_resources.*.file_ids of the agent and of every
# versions[] snapshot. Not touched: the `files` records, the vectors, updatedAt.
#
# Every run, dry or not, leaves an audit trail on the data disk with the HEAD
# results. An --apply trail records each changed array before and after, and
# --revert FILE puts them back wherever nothing has changed them since.
#
# Rehearsing on a copy that has no S3 credentials (staging):
#
#     scripts/remove-dead-agent-files.sh --head-results FILE [--apply]
#
# takes the HEAD results from FILE (a dry-run audit trail, or a bare array of
# { file_id, status, httpStatus }) instead of asking S3. Every candidate must
# have a recorded result. Never use it in production: the point is to ask S3
# at the moment of the change.
#
# Safe to run repeatedly. After a successful --apply, the next run finds no
# agent to change.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APPLY=false
REVERT_FILE=""
HEADS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=true;  shift ;;
    --dry-run)      APPLY=false; shift ;;
    --revert)       REVERT_FILE="${2:?--revert needs a file}"; shift 2 ;;
    --head-results) HEADS_FILE="${2:?--head-results needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "remove-dead-agent-files.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

env_value() {
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${1}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"
COMPOSE=(docker compose -f compose.yaml)

for f in "$REVERT_FILE" "$HEADS_FILE"; do
  if [ -n "$f" ] && [ ! -f "$f" ]; then
    echo "no such file: $f" >&2
    exit 1
  fi
done
if [ -n "$REVERT_FILE" ] && [ -n "$HEADS_FILE" ]; then
  echo "--revert and --head-results do not go together" >&2
  exit 2
fi

if [ "$APPLY" = true ]; then
  echo ""
  if [ -n "$REVERT_FILE" ]; then
    echo "  About to RESTORE agent file lists from $REVERT_FILE."
  else
    echo "  About to REMOVE file ids from agents and their version history."
    echo "  Run without --apply first and read what it proposes to remove."
  fi
  echo ""
  read -r -p "  Type 'apply' to continue: " reply
  [ "$reply" = "apply" ] || { echo "cancelled"; exit 1; }
fi

WORK="$(mktemp -d)"
CONTAINER_FILE="/tmp/dead-agent-files-input.json"
cleanup() {
  rm -rf "$WORK"
  "${COMPOSE[@]}" exec -T mongodb rm -f "$CONTAINER_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Lines between two markers of a captured output, markers excluded.
between() { sed -n "/===$1-BEGIN===/,/===$1-END===/p" "$2" | sed '1d;$d'; }

mongo() {
  "${COMPOSE[@]}" exec -T mongodb mongosh LibreChat --quiet "$@" --file /scripts/remove-dead-agent-files.js
}

if [ -n "$REVERT_FILE" ]; then
  "${COMPOSE[@]}" exec -T mongodb sh -c "cat > $CONTAINER_FILE" < "$REVERT_FILE"
  EVALS=(--eval "void (globalThis.MODE = 'revert')"
         --eval "void (globalThis.APPLY = ${APPLY})"
         --eval "void (globalThis.REVERT_FILE = '$CONTAINER_FILE')")
else
  # 1. The S3 files that agents reference. The list carries file paths, which
  #    can name documents, so it stays in a private temp file.
  mongo --eval "void (globalThis.MODE = 'candidates')" > "$WORK/candidates.out"
  between CANDIDATES-JSON "$WORK/candidates.out" > "$WORK/candidates.json"
  [ -s "$WORK/candidates.json" ] || { echo "could not list the candidates" >&2; cat "$WORK/candidates.out" >&2; exit 1; }

  # 2. Ask S3, from a one-off container of the app image: it has the SDK and
  #    the deployment's AWS settings, and works whether the app is up or not.
  if [ -n "$HEADS_FILE" ]; then
    cp "$HEADS_FILE" "$WORK/heads.json"
    SOURCE="recorded in $HEADS_FILE (NOT asked of S3 now)"
  elif [ "$(cat "$WORK/candidates.json")" = "[]" ]; then
    echo "[]" > "$WORK/heads.json"
    SOURCE="nothing to ask"
  else
    "${COMPOSE[@]}" run --rm --no-deps -T -v "$REPO_ROOT/scripts:/scripts:ro" \
      api node /scripts/head-s3-objects.js < "$WORK/candidates.json" > "$WORK/heads.out"
    between HEADS-JSON "$WORK/heads.out" > "$WORK/heads.json"
    [ -s "$WORK/heads.json" ] || { echo "the S3 check gave no result" >&2; cat "$WORK/heads.out" >&2; exit 1; }
    SOURCE="HEAD from this run, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  "${COMPOSE[@]}" exec -T mongodb sh -c "cat > $CONTAINER_FILE" < "$WORK/heads.json"
  EVALS=(--eval "void (globalThis.MODE = 'plan')"
         --eval "void (globalThis.APPLY = ${APPLY})"
         --eval "void (globalThis.HEADS_FILE = '$CONTAINER_FILE')"
         --eval "void (globalThis.HEADS_SOURCE = $(printf '%s' "$SOURCE" | sed 's/["\\]/\\&/g; s/.*/"&"/'))")
fi

set +e
mongo "${EVALS[@]}" | sed '/===CHANGELOG-JSON-BEGIN===/,/===CHANGELOG-JSON-END===/!b;w '"$WORK/changelog.out"'
d'
STATUS=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------
# Keep the audit trail, on the data disk where Azure Backup covers it.
# ---------------------------------------------------------------------------
CHANGELOG_DIR="${DATA_DIR}/migrations"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
case "${REVERT_FILE:+revert}-${APPLY}" in
  revert-true)  SUFFIX="revert" ;;
  revert-false) SUFFIX="revert-dry-run" ;;
  -true)        SUFFIX="apply" ;;
  *)            SUFFIX="dry-run" ;;
esac
CHANGELOG_FILE="${CHANGELOG_DIR}/dead-agent-files-${STAMP}-${SUFFIX}.json"

if [ -s "$WORK/changelog.out" ]; then
  mkdir -p "$CHANGELOG_DIR"
  sed '1d;$d' "$WORK/changelog.out" > "$CHANGELOG_FILE"
  chmod 600 "$CHANGELOG_FILE"
  echo "  Audit trail: $CHANGELOG_FILE"
  if [ "$SUFFIX" = "apply" ] && [ "$STATUS" -eq 0 ]; then
    echo "  To undo:     scripts/remove-dead-agent-files.sh --revert $CHANGELOG_FILE --apply"
  fi
fi

exit "$STATUS"
