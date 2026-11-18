#!/usr/bin/env bash
#
# Keep containers away from the Azure Instance Metadata Service (IMDS).
#
#   container-imds-guard.sh --apply   add the rule if it is missing (idempotent)
#   container-imds-guard.sh --check   exit 0 only if the rule is in place
#
# Why: IMDS (169.254.169.254) hands out tokens for the VM's managed identity to
# anything that can reach it. That identity reads every Key Vault secret and
# writes the backup storage account. Without this rule every container on the
# VM — LibreChat, the MCP servers, the admin panel, Caddy, the RAG API — could
# ask for those tokens, so a flaw in any one of them would expose all of it.
#
# The host itself still reaches IMDS: deploy.sh, render-env.sh and the backup
# job run in the host's network namespace, whose traffic never passes through
# Docker's DOCKER-USER chain. Only forwarded (container) traffic is dropped.
#
# Installed and kept running by infra/systemd/librechat-imds-guard.service,
# which scripts/install-imds-guard.sh puts in place on every deploy.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "container-imds-guard.sh must run as root" >&2
  exit 1
fi

RULE=(-d 169.254.169.254/32
      -m comment --comment "librechat: containers may not reach IMDS"
      -j DROP)

# Docker creates DOCKER-USER and hooks it into FORWARD when it starts. If the
# chain is missing, Docker is not managing the firewall and this rule would
# not be consulted, so say so rather than create a chain nothing jumps to.
if ! iptables -n -L DOCKER-USER >/dev/null 2>&1; then
  echo "DOCKER-USER chain not found: is Docker running with its iptables integration?" >&2
  exit 1
fi

case "${1:-}" in
  --apply)
    if ! iptables -C DOCKER-USER "${RULE[@]}" 2>/dev/null; then
      # First position, ahead of anything else in the chain.
      iptables -I DOCKER-USER 1 "${RULE[@]}"
      echo "added: containers may not reach 169.254.169.254"
    fi
    ;;
  --check)
    iptables -C DOCKER-USER "${RULE[@]}" 2>/dev/null
    ;;
  *)
    echo "usage: $0 --apply | --check" >&2
    exit 2
    ;;
esac
