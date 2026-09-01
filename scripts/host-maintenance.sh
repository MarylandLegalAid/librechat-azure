#!/usr/bin/env bash
#
# Bound growth of disposable host artifacts that live on the OS disk.
#
# Docker container logs are handled separately by compose.yaml's logging
# policy. This script removes only artifacts that are safe to fetch again:
#
#   - Docker images older than seven days and unused by every container
#   - inactive VS Code Server builds older than 30 days
#
# It defaults to a dry run. The systemd service passes --apply.

set -euo pipefail

MODE=dry-run
case "${1:-}" in
  "") ;;
  --dry-run) ;;
  --apply) MODE=apply ;;
  --help|-h)
    echo "Usage: $0 [--dry-run|--apply]"
    exit 0
    ;;
  *)
    echo "host-maintenance.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac

DOCKER_RETENTION_HOURS="${LIBRECHAT_DOCKER_IMAGE_RETENTION_HOURS:-168}"
VSCODE_RETENTION_DAYS="${LIBRECHAT_VSCODE_SERVER_RETENTION_DAYS:-30}"
VSCODE_HOME_ROOT="${LIBRECHAT_VSCODE_HOME_ROOT:-/home}"
LOCK_FILE="${LIBRECHAT_HOST_MAINTENANCE_LOCK:-/var/lock/librechat-deploy.lock}"

case "$DOCKER_RETENTION_HOURS" in
  ''|*[!0-9]*) echo "Docker retention must be a whole number of hours" >&2; exit 2 ;;
esac
case "$VSCODE_RETENTION_DAYS" in
  ''|*[!0-9]*) echo "VS Code retention must be a whole number of days" >&2; exit 2 ;;
esac

log() { echo "[host-maintenance $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Docker pruning and a deployment must not overlap. If the deploy timer owns
# this lock, it retries in five minutes; if this weekly job owns it, the deploy
# timer does the same.
exec 9>"$LOCK_FILE"
if ! flock --nonblock 9; then
  log "a deployment is in progress; leaving everything unchanged"
  exit 0
fi

prune_docker_images() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker is not installed; skipping image cleanup"
    return
  fi

  if [ "$MODE" = dry-run ]; then
    log "would prune images older than ${DOCKER_RETENTION_HOURS} hours and unused by every container"
    docker system df || true
    return
  fi

  log "pruning images older than ${DOCKER_RETENTION_HOURS} hours and unused by every container"
  docker image prune --all --force --filter "until=${DOCKER_RETENTION_HOURS}h"
}

declare -A ACTIVE_VSCODE_BUILDS=()
while IFS= read -r build; do
  [ -n "$build" ] && ACTIVE_VSCODE_BUILDS["$build"]=1
done < <(
  # Match the exact executable path embedded in Remote SSH process arguments;
  # pgrep cannot extract the commit hash from those arguments for us.
  # shellcheck disable=SC2009
  ps -eo args= \
    | grep -oE '\.vscode-server/code-[0-9a-f]{40}' \
    | sed 's#.*code-##' \
    | sort -u \
    || true
)

remove_vscode_build() {
  local candidate="$1" base build resolved
  base="$(basename "$candidate")"

  case "$base" in
    Stable-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) build="${base#Stable-}" ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) build="$base" ;;
    *) return ;;
  esac

  # A VS Code commit hash is exactly 40 lowercase hexadecimal characters.
  if ! [[ "$build" =~ ^[0-9a-f]{40}$ ]]; then
    return
  fi

  if [ -n "${ACTIVE_VSCODE_BUILDS[$build]:-}" ]; then
    log "retaining active VS Code Server build $build"
    return
  fi

  resolved="$(readlink -f -- "$candidate")"
  case "$resolved" in
    "$VSCODE_HOME_ROOT"/*/.vscode-server/cli/servers/Stable-"$build"|\
    "$VSCODE_HOME_ROOT"/*/.vscode-server/bin/"$build") ;;
    *)
      log "refusing unexpected VS Code Server path: $resolved"
      return
      ;;
  esac

  if [ "$MODE" = dry-run ]; then
    log "would remove inactive VS Code Server build: $resolved"
  else
    log "removing inactive VS Code Server build: $resolved"
    rm -rf --one-file-system -- "$resolved"
  fi
}

prune_vscode_servers() {
  if [ ! -d "$VSCODE_HOME_ROOT" ]; then
    log "$VSCODE_HOME_ROOT does not exist; skipping VS Code Server cleanup"
    return
  fi

  log "checking for inactive VS Code Server builds older than ${VSCODE_RETENTION_DAYS} days"

  # Modern Remote SSH clients use cli/servers/Stable-<commit>; older clients
  # used bin/<commit>. Exact depths and hash validation keep deletion tightly
  # scoped even if a home directory contains an unexpected symlink or name.
  while IFS= read -r -d '' candidate; do
    remove_vscode_build "$candidate"
  done < <(
    find "$VSCODE_HOME_ROOT" -xdev -mindepth 5 -maxdepth 5 -type d \
      -path '*/.vscode-server/cli/servers/Stable-*' \
      -mtime "+$VSCODE_RETENTION_DAYS" -print0
  )

  while IFS= read -r -d '' candidate; do
    remove_vscode_build "$candidate"
  done < <(
    find "$VSCODE_HOME_ROOT" -xdev -mindepth 4 -maxdepth 4 -type d \
      -path '*/.vscode-server/bin/*' \
      -mtime "+$VSCODE_RETENTION_DAYS" -print0
  )
}

log "starting $MODE run"
prune_docker_images
prune_vscode_servers
log "$MODE run complete"
