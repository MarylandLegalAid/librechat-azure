#!/usr/bin/env bash
#
# Build .env from two sources: the committed defaults, then Azure Key Vault.
#
#     env.defaults  (from git)  →  Azure Key Vault  →  .env  (mode 0600)
#
# Key Vault wins on conflict, so a deployment customizes itself by writing
# secrets rather than by editing files that would then conflict on every pull.
#
# No credential is stored anywhere on this machine. The VM has a system-assigned
# managed identity holding the "Key Vault Secrets User" role, and `az login
# --identity` exchanges the instance's own identity for a token. There is no
# password, key file, or service principal to rotate or leak.
#
# Run by scripts/deploy.sh. Running it by hand is safe and just rewrites .env.
#
# Usage:  scripts/render-env.sh [--vault NAME]
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS_FILE="$REPO_ROOT/env.defaults"
ENV_FILE="$REPO_ROOT/.env"

# The vault name comes from /etc/librechat-deploy.conf, which cloud-init writes
# at provisioning time. It is the one piece of per-machine configuration that
# cannot itself come from the vault.
VAULT_NAME="${KV_NAME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_NAME="$2"; shift 2 ;;
    *) echo "render-env.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VAULT_NAME" ]; then
  echo "render-env.sh: no Key Vault name." >&2
  echo "  Set KV_NAME in /etc/librechat-deploy.conf, or pass --vault NAME." >&2
  exit 2
fi

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "render-env.sh: $DEFAULTS_FILE is missing. Is this a complete checkout?" >&2
  exit 1
fi

log() { echo "[render-env] $*"; }


# -----------------------------------------------------------------------------
# 1. Authenticate as the VM itself.
# -----------------------------------------------------------------------------
# If someone is already signed in (an administrator running this by hand from a
# workstation), use that session rather than overriding it.
if az account show >/dev/null 2>&1; then
  log "using the existing Azure CLI session"
else
  log "signing in with the VM's managed identity"
  az login --identity --allow-no-subscriptions --output none
fi


# -----------------------------------------------------------------------------
# 2. Read the committed defaults.
# -----------------------------------------------------------------------------
# `values` maps NAME -> value. Starting from the defaults and then overwriting
# from the vault is what makes "Key Vault wins" true, in one place, visibly.
declare -A values=()

while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank lines and comments.
  case "$line" in ''|'#'*) continue ;; esac
  # Everything before the first '=' is the name; everything after is the value,
  # kept exactly as written. Values legitimately contain '=' (base64, JSON).
  name="${line%%=*}"
  value="${line#*=}"
  [ -n "$name" ] || continue
  values["$name"]="$value"
done < "$DEFAULTS_FILE"

log "loaded ${#values[@]} defaults from env.defaults"


# -----------------------------------------------------------------------------
# 3. Overlay Azure Key Vault.
# -----------------------------------------------------------------------------
# Azure forbids underscores in secret names, so the convention is that a dash in
# a secret name becomes an underscore in the environment variable:
#
#     OPENID-CLIENT-SECRET  →  OPENID_CLIENT_SECRET
#
# This is the single most common source of confusion when setting this up. A
# secret stored with the wrong name is not an error — it simply never becomes
# the variable you expected, and the application starts up missing it.
log "reading secrets from Key Vault '$VAULT_NAME'"

secret_names="$(
  az keyvault secret list \
    --vault-name "$VAULT_NAME" \
    --query "[?attributes.enabled].name" \
    --output tsv
)"

if [ -z "$secret_names" ]; then
  echo "render-env.sh: the vault '$VAULT_NAME' returned no enabled secrets." >&2
  echo "  Either it has not been seeded yet, or this machine's managed identity" >&2
  echo "  is missing the 'Key Vault Secrets User' role on it." >&2
  exit 1
fi

secret_count=0
while IFS= read -r secret_name; do
  [ -n "$secret_name" ] || continue

  value="$(az keyvault secret show \
             --vault-name "$VAULT_NAME" \
             --name "$secret_name" \
             --query value \
             --output tsv)"

  var_name="${secret_name//-/_}"

  # A .env file has no line-continuation syntax, so a multi-line value would
  # silently truncate at the first newline and leave the rest of the file
  # malformed. Refuse rather than produce a subtly broken .env.
  if [ "$value" != "${value//$'\n'/}" ]; then
    echo "render-env.sh: secret '$secret_name' contains a newline." >&2
    echo "  .env cannot represent multi-line values. Store it as a single line —" >&2
    echo "  for a private key in JWK form, that means one line of compact JSON." >&2
    exit 1
  fi

  values["$var_name"]="$value"
  secret_count=$((secret_count + 1))
done <<< "$secret_names"

log "applied $secret_count secrets"


# -----------------------------------------------------------------------------
# 4. Write .env atomically.
# -----------------------------------------------------------------------------
# Written to a temporary file with restrictive permissions and then moved into
# place, so no reader ever sees a half-written .env and the file is never
# briefly world-readable.
umask 077
tmp_file="$(mktemp "${ENV_FILE}.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

{
  echo "# Generated by scripts/render-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# DO NOT EDIT. Every deploy overwrites this file."
  echo "#"
  echo "# To change a value: edit env.defaults (for all deployments) or set the"
  echo "# corresponding Key Vault secret (for this one). See .env.example."
  echo ""
  # Sorted so that diffing two generated .env files shows real changes rather
  # than reordering.
  for name in $(printf '%s\n' "${!values[@]}" | sort); do
    printf '%s=%s\n' "$name" "${values[$name]}"
  done
} > "$tmp_file"

chmod 0600 "$tmp_file"
mv -f "$tmp_file" "$ENV_FILE"
trap - EXIT

log "wrote $ENV_FILE with ${#values[@]} variables (mode 0600)"
