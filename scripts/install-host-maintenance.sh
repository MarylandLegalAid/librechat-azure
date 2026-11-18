#!/usr/bin/env bash
# Install or update the versioned systemd timers that maintain the host:
#   librechat-host-maintenance  weekly storage pruning
#   librechat-preview-cert      daily Sandpack preview certificate check (a
#                               no-op when PREVIEW_DOMAIN is not set)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install-host-maintenance.sh must run as root" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SOURCE="$REPO_ROOT/infra/systemd"
UNIT_DEST=/etc/systemd/system

for name in librechat-host-maintenance librechat-preview-cert; do
  changed=false
  for unit in "$name.service" "$name.timer"; do
    if ! cmp -s "$UNIT_SOURCE/$unit" "$UNIT_DEST/$unit"; then
      install -m 0644 "$UNIT_SOURCE/$unit" "$UNIT_DEST/$unit"
      changed=true
    fi
  done

  if [ "$changed" = true ]; then
    systemctl daemon-reload
  fi

  systemctl enable "$name.timer" >/dev/null
  if [ "$changed" = true ] || ! systemctl is-active --quiet "$name.timer"; then
    systemctl restart "$name.timer"
  fi
done
