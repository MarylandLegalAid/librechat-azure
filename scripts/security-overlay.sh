#!/usr/bin/env bash
# Print the optional image override only after checking its scope and baseline.
# Called afresh for both deployment and rollback, after the checkout changes.
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
overlay="$root/compose.security.yml"
[ -f "$overlay" ] || exit 0

fail() { echo "security-overlay: $*" >&2; exit 1; }
json="$(yq -o=json '.' "$overlay")" || fail "invalid YAML"
if ! jq -e '
  (keys == ["services", "x-security-patch"]) and
  (.services | keys == ["api"]) and
  (.services.api | keys == ["image"]) and
  (.services.api.image | type == "string") and
  (.services.api.image | test("^[a-z0-9./:_-]+@sha256:[a-f0-9]{64}$")) and
  (."x-security-patch"."upstream-image" | type == "string")
' >/dev/null <<< "$json"; then
  fail "override must contain only api.image, pinned by digest, and x-security-patch.upstream-image"
fi
base="$(yq -r '.services.api.image' "$root/compose.yaml")"
expected="$(jq -r '."x-security-patch"."upstream-image"' <<< "$json")"
[ "$base" = "$expected" ] || fail "hotfix supports $expected but compose.yaml selects $base; remove or rebuild the hotfix before upgrading"
printf '%s\n' "$overlay"
