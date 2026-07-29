#!/usr/bin/env bash
#
# The only thing that ever deploys this stack.
#
# Two different triggers call this same script, which is the point: a grantee's
# five-minute systemd timer and Maryland Legal Aid's GitHub Actions pipeline run
# identical code, so neither path can rot while the other is exercised.
#
#     systemd timer   →  deploy.sh          (checks for new commits, usually exits)
#     GitHub Actions  →  deploy.sh --force  (deploy this commit now)
#
# What it does, in order:
#
#     1.  take a lock, so two runs cannot overlap
#     2.  remember the current commit, for rollback
#     3.  fast-forward to origin/main; stop here if nothing changed
#     4.  rebuild .env from Azure Key Vault
#     5.  merge librechat.yaml with the storage overlay
#     6.  pull images
#     7.  start containers
#     8.  wait for the health endpoint
#     9.  on failure: roll back to the previous commit and start it again
#
# It is safe to run at any time, as often as you like. If nothing has changed it
# does almost nothing, which is what makes a five-minute timer nearly free.
#
# Usage:  deploy.sh [--force]
#
#   --force   Deploy even when the commit has not changed. Use this after
#             changing a Key Vault secret, since that leaves git untouched.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOCK_FILE="/var/lock/librechat-deploy.lock"
CONFIG_FILE="/etc/librechat-deploy.conf"
BRANCH="${DEPLOY_BRANCH:-main}"
# /health, not /healthz — the latter returns 200 with the frontend's HTML from
# the catch-all route, so it passes even when the API is down. /api/health does
# not exist at all. Verified by probing v0.8.7 directly.
HEALTH_URL="http://127.0.0.1:3080/health"
HEALTH_TIMEOUT_SECONDS=120

FORCE=false
REEXECED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    # Internal. Set when this script has already re-executed itself after
    # updating, so it cannot do so twice.
    --reexeced) REEXECED=true; shift ;;
    *) echo "deploy.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { echo "[deploy $(date -u +%H:%M:%S)] $*"; }
fail() { echo "[deploy] ERROR: $*" >&2; }

# Per-machine settings written by cloud-init at provisioning time: KV_NAME, and
# optionally DEPLOY_BRANCH. Everything else comes from git or the vault.
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
# Exported, not merely set: render-env.sh and backup-mongo.sh are separate
# processes and inherit only the environment. (They also read this file
# themselves now, but relying on one mechanism to work by accident is how the
# first real deploy failed.)
export KV_NAME="${KV_NAME:-}"
export DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
export REPO_URL="${REPO_URL:-}"


# -----------------------------------------------------------------------------
# 1. Take the lock.
# -----------------------------------------------------------------------------
# A timer run and a pipeline run can genuinely coincide. Exiting quietly is the
# right response: whichever run holds the lock is already doing the work.
exec 9>"$LOCK_FILE"
if ! flock --nonblock 9; then
  log "another deploy is already running; nothing to do"
  exit 0
fi


# -----------------------------------------------------------------------------
# 2. Read the previous commit, so a failure has somewhere to go back to.
# -----------------------------------------------------------------------------
PREVIOUS_SHA="$(git rev-parse HEAD)"
log "current commit: ${PREVIOUS_SHA:0:12}"


# -----------------------------------------------------------------------------
# 3. Fast-forward to the branch.
# -----------------------------------------------------------------------------
# `reset --hard` rather than `pull`: the checkout on this machine is a mirror of
# the branch, never a place where edits are made. Anything modified here by hand
# is discarded on the next deploy, deliberately — the repository is the only
# source of truth for configuration, and there is nowhere else to look.
log "fetching origin/$BRANCH"
git fetch --quiet origin "$BRANCH"
git reset --quiet --hard "origin/$BRANCH"

CURRENT_SHA="$(git rev-parse HEAD)"

if [ "$CURRENT_SHA" = "$PREVIOUS_SHA" ] && [ "$FORCE" = false ]; then
  log "already up to date at ${CURRENT_SHA:0:12}; nothing to do"
  exit 0
fi

if [ "$CURRENT_SHA" != "$PREVIOUS_SHA" ]; then
  log "updating ${PREVIOUS_SHA:0:12} -> ${CURRENT_SHA:0:12}"
else
  log "forced redeploy of ${CURRENT_SHA:0:12}"
fi


# -----------------------------------------------------------------------------
# 3b. If this script itself just changed, run the NEW one.
# -----------------------------------------------------------------------------
# Step 3 rewrote the working tree, including possibly this file — while this
# file is being executed. Two things follow, and the first one is subtle enough
# to have already caused a confusing failure:
#
#   - The running process keeps the OLD logic. A fix to deploy.sh appears not to
#     work, then works on the next run, which is a maddening thing to debug.
#   - Worse, bash reads a script incrementally by byte offset. A file that
#     changes length underneath it can leave the interpreter reading from the
#     wrong position and executing fragments of lines.
#
# Re-executing closes both. The lock on file descriptor 9 survives exec, so
# this does not deadlock against itself, and --reexeced stops it recursing.
if [ "$REEXECED" = false ] && [ "$CURRENT_SHA" != "$PREVIOUS_SHA" ] \
   && ! git diff --quiet "$PREVIOUS_SHA" "$CURRENT_SHA" -- scripts/deploy.sh; then
  log "deploy.sh changed in this update; re-executing the new version"
  exec "$REPO_ROOT/scripts/deploy.sh" --reexeced $([ "$FORCE" = true ] && echo --force)
fi


# -----------------------------------------------------------------------------
# Helpers used by the deploy and by the rollback.
# -----------------------------------------------------------------------------

# Read one value out of .env without executing it. Sourcing the file would be
# shorter and wrong: values legitimately contain spaces and asterisks, which the
# shell would expand.
env_value() {
  local name="$1"
  [ -f "$REPO_ROOT/.env" ] || return 0
  grep -m1 "^${name}=" "$REPO_ROOT/.env" | cut -d= -f2- || true
}

# Everything from "rebuild .env" through "start containers". Run once normally,
# and once more against the previous commit if the health check fails.
bring_up_stack() {
  # --- 4. Rebuild .env from Key Vault --------------------------------------
  #
  # Checked explicitly rather than left to `set -e`. This function is invoked as
  # `if ! bring_up_stack`, and POSIX shells disable errexit for a command used
  # as a condition — so every failure inside here is silent unless it is tested.
  # Without this check, a secrets failure fell straight through to `docker
  # compose up` with no .env at all, and the first error a human saw was an
  # unrelated complaint about an unset variable.
  log "rendering .env from Key Vault"
  if ! "$REPO_ROOT/scripts/render-env.sh"; then
    fail "could not render .env from Key Vault — not starting anything."
    fail "Check that KV_NAME in $CONFIG_FILE names a real vault, and that this"
    fail "machine's managed identity holds 'Key Vault Secrets User' on it."
    return 1
  fi

  local file_storage data_dir compose_profiles
  file_storage="$(env_value FILE_STORAGE)"
  file_storage="${file_storage:-disk}"
  data_dir="$(env_value DATA_DIR)"
  data_dir="${data_dir:-/srv/librechat/data}"
  compose_profiles="$(env_value COMPOSE_PROFILES)"

  local storage_config="config/storage/${file_storage}.yaml"
  local storage_compose="compose.storage.${file_storage}.yml"

  if [ ! -f "$storage_config" ] || [ ! -f "$storage_compose" ]; then
    fail "FILE_STORAGE='${file_storage}' has no overlay."
    fail "Expected $storage_config and $storage_compose. Valid values are the"
    fail "names in config/storage/ — see config/storage/README.md."
    return 1
  fi

  # The databases write straight to the data disk. If it failed to mount, the
  # mount point is an ordinary empty directory on the OS disk, and the stack
  # would start up looking perfectly healthy and completely empty — then write
  # new data somewhere that is not backed up and disappears at the next reboot.
  # Refusing here turns a silent data-loss scenario into an obvious failure.
  if ! mountpoint --quiet "$data_dir"; then
    fail "$data_dir is not a mounted filesystem."
    fail "The data disk is missing. Refusing to start: the stack would come up"
    fail "empty and write to the OS disk. Check 'lsblk' and /etc/fstab, and see"
    fail "docs/troubleshooting.md."
    return 1
  fi

  # --- 5. Assemble the runtime config --------------------------------------
  # fileStrategy cannot be an environment variable — LibreChat parses it as a
  # zod enum and does not interpolate ${VAR} into that key. So the choice is
  # baked in here, before the application ever reads the file.
  # config/storage/README.md explains this at length.
  log "merging librechat.yaml with $storage_config"
  if ! yq eval-all '. as $item ireduce ({}; . * $item)' \
       librechat.yaml "$storage_config" > librechat.runtime.yaml; then
    fail "failed to merge librechat.yaml with $storage_config"
    return 1
  fi

  # --- 6 & 7. Pull and start ------------------------------------------------
  local -a compose_args=(-f compose.yaml -f "$storage_compose")
  if [ -n "$compose_profiles" ]; then
    log "optional services: $compose_profiles"
    local profile
    # shellcheck disable=SC2001
    for profile in $(echo "$compose_profiles" | tr ',' ' '); do
      compose_args+=(--profile "$profile")
    done
  fi

  log "pulling images"
  if ! docker compose "${compose_args[@]}" pull --quiet; then
    fail "failed to pull one or more images"
    return 1
  fi

  log "starting containers"
  if ! docker compose "${compose_args[@]}" up -d --remove-orphans; then
    fail "failed to start containers"
    return 1
  fi
}

# Poll the application's own health endpoint. Container "running" is not the
# same as application "working" — a crash-looping container and a container
# stuck on a bad config both report as up to Docker.
wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  log "waiting up to ${HEALTH_TIMEOUT_SECONDS}s for $HEALTH_URL"
  while [ $SECONDS -lt $deadline ]; do
    if curl --fail --silent --show-error --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      log "healthy"
      return 0
    fi
    sleep 5
  done
  return 1
}


# -----------------------------------------------------------------------------
# Deploy.
# -----------------------------------------------------------------------------
deploy_failed=false

if ! bring_up_stack; then
  fail "failed to start the stack at ${CURRENT_SHA:0:12}"
  deploy_failed=true
elif ! wait_for_health; then
  fail "the stack started but never became healthy at ${CURRENT_SHA:0:12}"
  docker compose -f compose.yaml logs --tail 50 api || true
  deploy_failed=true
fi


# -----------------------------------------------------------------------------
# 9. Roll back.
# -----------------------------------------------------------------------------
if [ "$deploy_failed" = true ]; then
  if [ "$CURRENT_SHA" = "$PREVIOUS_SHA" ]; then
    fail "-------------------------------------------------------------------"
    fail "DEPLOY FAILED and there is nothing to roll back to — this commit is"
    fail "already what was running. The stack is DOWN or UNHEALTHY."
    fail "Look at: docker compose -f compose.yaml logs --tail 200 api"
    fail "-------------------------------------------------------------------"
    exit 1
  fi

  fail "-------------------------------------------------------------------"
  fail "DEPLOY FAILED. Rolling back ${CURRENT_SHA:0:12} -> ${PREVIOUS_SHA:0:12}"
  fail "-------------------------------------------------------------------"

  git reset --quiet --hard "$PREVIOUS_SHA"

  if bring_up_stack && wait_for_health; then
    fail "rolled back successfully; running ${PREVIOUS_SHA:0:12}"
    fail "The bad commit is still on origin/$BRANCH. The next timer run will"
    fail "try it again and fail again. Fix it or revert it on the branch."
  else
    fail "-------------------------------------------------------------------"
    fail "ROLLBACK ALSO FAILED. The stack is DOWN. This needs a human now."
    fail "  docker compose -f compose.yaml ps"
    fail "  docker compose -f compose.yaml logs --tail 200 api"
    fail "-------------------------------------------------------------------"
  fi

  exit 1
fi

log "deployed ${CURRENT_SHA:0:12} successfully"
