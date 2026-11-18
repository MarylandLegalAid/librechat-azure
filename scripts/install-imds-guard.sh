#!/usr/bin/env bash
# Install or update the unit that keeps containers away from the Azure
# instance metadata endpoint, start it, and confirm the rule is in place.
# Run by deploy.sh on every deploy; exits non-zero if the rule is not active.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install-imds-guard.sh must run as root" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT=librechat-imds-guard.service
SRC="$REPO_ROOT/infra/systemd/$UNIT"
DEST="/etc/systemd/system/$UNIT"
changed=false

if ! cmp -s "$SRC" "$DEST"; then
  install -m 0644 "$SRC" "$DEST"
  systemctl daemon-reload
  changed=true
fi

systemctl enable "$UNIT" >/dev/null 2>&1
if [ "$changed" = true ] || ! systemctl is-active --quiet "$UNIT"; then
  systemctl restart "$UNIT"
fi

# The unit stays "active" after it ran once (RemainAfterExit), even if the
# rule was flushed since. Re-apply, then check the rule itself.
"$REPO_ROOT/scripts/container-imds-guard.sh" --apply
"$REPO_ROOT/scripts/container-imds-guard.sh" --check
