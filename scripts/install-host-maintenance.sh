#!/usr/bin/env bash
# Install or update the versioned systemd units for host storage maintenance.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install-host-maintenance.sh must run as root" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SOURCE="$REPO_ROOT/infra/systemd"
UNIT_DEST=/etc/systemd/system
TIMER=librechat-host-maintenance.timer
changed=false

for unit in librechat-host-maintenance.service "$TIMER"; do
  if ! cmp -s "$UNIT_SOURCE/$unit" "$UNIT_DEST/$unit"; then
    install -m 0644 "$UNIT_SOURCE/$unit" "$UNIT_DEST/$unit"
    changed=true
  fi
done

if [ "$changed" = true ]; then
  systemctl daemon-reload
fi

systemctl enable "$TIMER" >/dev/null
if [ "$changed" = true ] || ! systemctl is-active --quiet "$TIMER"; then
  systemctl restart "$TIMER"
fi
