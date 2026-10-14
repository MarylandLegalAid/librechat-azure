#!/usr/bin/env bash
#
# The only thing that ever deploys the code interpreter stack. OPTIONAL module;
# see docs/modules/code-interpreter.md.
#
# The interpreter VM's counterpart to scripts/deploy.sh, and deliberately the
# same shape: a five-minute timer runs it, it usually finds nothing new and
# exits, and when there is something new it renders .env from Key Vault, pulls,
# starts, waits for health, and rolls back to the previous commit on failure.
#
#     systemd timer  →  codeinterpreter-deploy.sh          (usually exits)
#     by hand        →  codeinterpreter-deploy.sh --force  (after a secret change)
#
# It runs from a checkout of this whole repository at /srv/codeinterpreter/app,
# and uses only codeinterpreter/ and a handful of scripts from it.
#
# Usage:  codeinterpreter-deploy.sh [--force]
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STACK_DIR="$REPO_ROOT/codeinterpreter"
LOCK_FILE="/var/lock/codeinterpreter-deploy.lock"
CONFIG_FILE="/etc/codeinterpreter-deploy.conf"
# Unauthenticated, and answers only when the API can reach Redis.
HEALTH_URL="http://127.0.0.1:3112/v1/health"
HEALTH_TIMEOUT_SECONDS=300

FORCE=false
REEXECED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --reexeced) REEXECED=true; shift ;;
    *) echo "codeinterpreter-deploy.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { echo "[ci-deploy $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[ci-deploy] ERROR: $*" >&2; }

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
export KV_NAME="${KV_NAME:-}"
export DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
BRANCH="$DEPLOY_BRANCH"

COMPOSE=(docker compose -f "$STACK_DIR/compose.yaml")

# --- 1. Lock ------------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock --nonblock 9; then
  log "another deploy is already running; nothing to do"
  exit 0
fi

# --- 2 & 3. Fast-forward ------------------------------------------------------
# Same as deploy.sh: the checkout is a mirror, and the refspec is explicit
# because the clone is single-branch.
PREVIOUS_SHA="$(git rev-parse HEAD)"
log "fetching origin/$BRANCH"
git fetch --quiet origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
git reset --quiet --hard "origin/$BRANCH"
CURRENT_SHA="$(git rev-parse HEAD)"

if [ "$CURRENT_SHA" = "$PREVIOUS_SHA" ] && [ "$FORCE" = false ]; then
  log "already up to date at ${CURRENT_SHA:0:12}; nothing to do"
  exit 0
fi
log "deploying ${PREVIOUS_SHA:0:12} -> ${CURRENT_SHA:0:12}"

# Run the new copy of this script if the update changed it. deploy.sh explains
# why at length; --force is required for the same reason.
if [ "$REEXECED" = false ] && [ "$CURRENT_SHA" != "$PREVIOUS_SHA" ] \
   && ! git diff --quiet "$PREVIOUS_SHA" "$CURRENT_SHA" -- scripts/codeinterpreter-deploy.sh; then
  log "this script changed in the update; re-executing the new version"
  exec "$REPO_ROOT/scripts/codeinterpreter-deploy.sh" --reexeced --force
fi

# --- 3b. Host units -----------------------------------------------------------
"$REPO_ROOT/scripts/install-codeinterpreter-units.sh"

# Config directories whose container must restart to see a change. Each is
# bind-mounted as a directory, so the new files are visible immediately; the
# process inside only reads them at start.
declare -A RESTART_ON_CHANGE=(
  [caddy]="codeinterpreter/caddy"
  [garage]="codeinterpreter/garage"
  [file-cleanup]="codeinterpreter/file-cleanup"
)

bring_up_stack() {
  local from_sha="$1"

  # --- 4. .env from Key Vault ---------------------------------------------
  log "rendering codeinterpreter/.env from Key Vault"
  if ! DEFAULTS_FILE="$STACK_DIR/env.defaults" ENV_FILE="$STACK_DIR/.env" \
       CONFIG_FILE="$CONFIG_FILE" "$REPO_ROOT/scripts/render-env.sh"; then
    fail "could not render .env from Key Vault — not starting anything."
    fail "Check KV_NAME in $CONFIG_FILE and this machine's 'Key Vault Secrets User' role."
    return 1
  fi

  # Without /dev/kvm the sandbox cannot start at all, and the failure shows up
  # as a health check that never passes. Say so plainly instead.
  if [ ! -c /dev/kvm ]; then
    fail "/dev/kvm is missing. This VM size does not support nested virtualization."
    fail "Use a Dv5/Ev5-class size; see docs/modules/code-interpreter.md."
    return 1
  fi

  install -d -m 0755 /var/lib/codeinterpreter/textfile

  # --- 5 & 6. Pull and start --------------------------------------------------
  log "pulling images"
  if ! "${COMPOSE[@]}" pull --quiet; then
    fail "failed to pull one or more images"
    return 1
  fi

  local -A before=()
  local service
  for service in "${!RESTART_ON_CHANGE[@]}"; do
    before[$service]="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
  done

  log "starting containers"
  if ! "${COMPOSE[@]}" up -d --remove-orphans; then
    fail "failed to start containers"
    return 1
  fi

  # A config-only change leaves the container in place; restart it so the new
  # config is read. A recreated container has already read it.
  local head_sha
  head_sha="$(git rev-parse HEAD)"
  for service in "${!RESTART_ON_CHANGE[@]}"; do
    if [ "$from_sha" != "$head_sha" ] \
       && ! git diff --quiet "$from_sha" HEAD -- "${RESTART_ON_CHANGE[$service]}" \
       && [ -n "${before[$service]}" ] \
       && [ "${before[$service]}" = "$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)" ]; then
      log "restarting $service so it re-reads its configuration"
      "${COMPOSE[@]}" restart "$service" || return 1
    fi
  done
}

wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local runner
  log "waiting up to ${HEALTH_TIMEOUT_SECONDS}s for the API and the sandbox"
  while [ $SECONDS -lt $deadline ]; do
    runner="$(docker inspect --format '{{.State.Health.Status}}' sandbox-runner 2>/dev/null || true)"
    if [ "$runner" = healthy ] \
       && curl --fail --silent --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      log "healthy"
      return 0
    fi
    sleep 5
  done
  return 1
}

deploy_failed=false
if ! bring_up_stack "$PREVIOUS_SHA"; then
  fail "failed to start the stack at ${CURRENT_SHA:0:12}"
  deploy_failed=true
elif ! wait_for_health; then
  fail "the stack started but never became healthy at ${CURRENT_SHA:0:12}"
  "${COMPOSE[@]}" ps || true
  deploy_failed=true
fi

if [ "$deploy_failed" = true ]; then
  if [ "$CURRENT_SHA" = "$PREVIOUS_SHA" ]; then
    fail "DEPLOY FAILED with nothing to roll back to. The interpreter is DOWN."
    fail "Look at: docker compose -f $STACK_DIR/compose.yaml logs --tail 200"
    exit 1
  fi
  fail "DEPLOY FAILED. Rolling back ${CURRENT_SHA:0:12} -> ${PREVIOUS_SHA:0:12}"
  git reset --quiet --hard "$PREVIOUS_SHA"
  if bring_up_stack "$CURRENT_SHA" && wait_for_health; then
    fail "rolled back; running ${PREVIOUS_SHA:0:12}. The bad commit is still on"
    fail "origin/$BRANCH and the next timer run will try it again."
  else
    fail "ROLLBACK ALSO FAILED. The interpreter is DOWN. This needs a human now."
  fi
  exit 1
fi

log "deployed ${CURRENT_SHA:0:12} successfully"
