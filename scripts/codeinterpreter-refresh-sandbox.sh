#!/usr/bin/env bash
#
# After a reboot, restart the sandbox once the egress gateway is healthy.
#
# Docker's restart policies bring containers back in no particular order, so the
# sandbox can start before the gateway it forwards to. When that happens its
# micro-VM-side forwarder never connects, executions still run, and every
# generated file silently fails to come back. Restarting the sandbox after the
# gateway is healthy rebuilds the forwarder. Compose's own depends_on ordering
# covers deploys; this covers boots. Run by codeinterpreter-boot.service.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$REPO_ROOT/codeinterpreter/compose.yaml")

wait_healthy() {
  local container="$1" status
  for _ in $(seq 1 90); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
    sleep 2
  done
  echo "[refresh-sandbox] $container did not become healthy" >&2
  return 1
}

if [ -z "$("${COMPOSE[@]}" ps -q sandbox-runner 2>/dev/null)" ]; then
  echo "[refresh-sandbox] the stack has not been deployed yet; nothing to do"
  exit 0
fi

wait_healthy egress_gateway
"${COMPOSE[@]}" restart sandbox-runner
wait_healthy sandbox-runner
echo "[refresh-sandbox] sandbox restarted behind a healthy gateway"
