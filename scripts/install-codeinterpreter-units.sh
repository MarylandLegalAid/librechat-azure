#!/usr/bin/env bash
# Install or update the code interpreter VM's versioned systemd units, from
# infra/codeinterpreter/systemd. Run by codeinterpreter-deploy.sh on every
# deploy, so a changed unit reaches existing machines the same way a changed
# compose file does. The deploy timer itself is written by cloud-init, because
# it has to exist before the first deploy.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install-codeinterpreter-units.sh must run as root" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SOURCE="$REPO_ROOT/infra/codeinterpreter/systemd"
UNIT_DEST=/etc/systemd/system
changed=()

for path in "$UNIT_SOURCE"/*.service "$UNIT_SOURCE"/*.timer; do
  unit="$(basename "$path")"
  if ! cmp -s "$path" "$UNIT_DEST/$unit"; then
    install -m 0644 "$path" "$UNIT_DEST/$unit"
    changed+=("$unit")
  fi
done

[ "${#changed[@]}" -gt 0 ] && systemctl daemon-reload

# Timers are enabled and (re)started. The boot unit is only enabled: it runs at
# the next boot, and running it now would restart the sandbox mid-deploy.
for path in "$UNIT_SOURCE"/*.timer; do
  timer="$(basename "$path")"
  systemctl enable "$timer" >/dev/null 2>&1
  if printf '%s\n' "${changed[@]}" | grep -qx "$timer" || ! systemctl is-active --quiet "$timer"; then
    systemctl restart "$timer"
  fi
done
systemctl enable codeinterpreter-boot.service >/dev/null 2>&1

# cloud-init enables the deploy timer but cannot start it before the first
# deploy. Start it here, once that deploy has run, unless it was disabled on
# purpose (enableDeployTimer=false).
if systemctl is-enabled --quiet codeinterpreter-deploy.timer 2>/dev/null \
   && ! systemctl is-active --quiet codeinterpreter-deploy.timer; then
  systemctl start codeinterpreter-deploy.timer
fi

[ "${#changed[@]}" -gt 0 ] && echo "[units] updated: ${changed[*]}"
exit 0
