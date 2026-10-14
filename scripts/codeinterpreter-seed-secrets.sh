#!/usr/bin/env bash
#
# Seed the code interpreter's Key Vault. Run once from an administrator's
# workstation, after infra/codeinterpreter/main.bicep and before the first
# deploy. OPTIONAL module; see docs/modules/code-interpreter.md.
#
#   scripts/codeinterpreter-seed-secrets.sh \
#     --vault <interpreter vault> --chat-vault <chat VM's vault> \
#     --domain code.example.org --acme-email ops@example.org
#
# What it writes:
#
#   Generated here, random, never shown:
#     REDIS-PASSWORD, CODEAPI-INTERNAL-SERVICE-TOKEN, CODEAPI-EGRESS-GRANT-SECRET,
#     GARAGE-RPC-SECRET, FILE-STORE-ACCESS-KEY, FILE-STORE-SECRET-KEY,
#     CODEAPI-EXECUTION-MANIFEST-PRIVATE-KEY and its public half
#     SANDBOX-EXECUTION-MANIFEST-PUBLIC-KEY (an Ed25519 pair, generated together)
#
#   Derived from the chat VM's vault, so the two sides cannot disagree:
#     CODEAPI-JWT-JWKS-JSON         the PUBLIC half of CODEAPI-JWT-PRIVATE-JWK-JSON
#     CODEAPI-JWT-KID               copied
#     CODEAPI-JWT-SINGLE-TENANT-ID  copied
#
#   From the arguments:
#     CODE-DOMAIN, ACME-EMAIL
#
# Idempotent: a secret that already exists is left alone, so re-running never
# rotates anything by accident. --rotate NAME replaces one generated secret.
# The JWT values are re-derived every run, so after rotating LibreChat's key
# pair, re-run this and redeploy the interpreter.
#
# Nothing secret is printed, passed on a command line, or left on disk: values
# go to `az keyvault secret set --file` through a private temporary directory
# that is removed on exit.
#
# Needs: az (signed in, with Key Vault Secrets Officer on --vault and Secrets
# User on --chat-vault), openssl, jq, python3 with `cryptography` installed.
#

set -euo pipefail

VAULT="" CHAT_VAULT="" DOMAIN="" ACME_EMAIL=""
ROTATE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --chat-vault) CHAT_VAULT="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --rotate) ROTATE+=("$2"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$VAULT" ] || [ -z "$CHAT_VAULT" ] || [ -z "$DOMAIN" ] || [ -z "$ACME_EMAIL" ]; then
  sed -n '7,11p' "$0" >&2
  exit 2
fi

log() { echo "[seed] $*"; }

WORK="$(mktemp -d)"
chmod 0700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

existing="$(az keyvault secret list --vault-name "$VAULT" --query "[].name" -o tsv)"
exists() { grep -qx "$1" <<<"$existing"; }
rotating() { printf '%s\n' "${ROTATE[@]}" | grep -qx "$1"; }

# Write the value held in file $2 to secret $1.
put() {
  az keyvault secret set --vault-name "$VAULT" --name "$1" --file "$2" \
    --encoding utf-8 --output none
}

# Generate secret $1 with command $2 unless it exists (or is being rotated).
generate() {
  local name="$1" cmd="$2"
  if exists "$name" && ! rotating "$name"; then
    log "$name: exists, left alone"
    return
  fi
  bash -c "$cmd" | tr -d '\n' > "$WORK/value"
  put "$name" "$WORK/value"
  log "$name: generated"
}

generate REDIS-PASSWORD                 'openssl rand -hex 32'
generate CODEAPI-INTERNAL-SERVICE-TOKEN 'openssl rand -hex 32'
generate CODEAPI-EGRESS-GRANT-SECRET    'openssl rand -hex 32'
generate GARAGE-RPC-SECRET              'openssl rand -hex 32'
# Garage access key IDs conventionally start with GK.
generate FILE-STORE-ACCESS-KEY          'printf GK; openssl rand -hex 12'
generate FILE-STORE-SECRET-KEY          'openssl rand -hex 32'

# The execution-manifest pair: the worker signs each execution with the private
# key and the sandbox refuses any execution not signed by it. The two must be
# generated together, so they are rotated together.
if exists CODEAPI-EXECUTION-MANIFEST-PRIVATE-KEY && exists SANDBOX-EXECUTION-MANIFEST-PUBLIC-KEY \
   && ! rotating CODEAPI-EXECUTION-MANIFEST-PRIVATE-KEY; then
  log "execution-manifest key pair: exists, left alone"
else
  # Base64 DER, no PEM armour: the format upstream reads.
  openssl genpkey -algorithm ed25519 -outform DER -out "$WORK/manifest.der" 2>/dev/null
  base64 -w0 "$WORK/manifest.der" > "$WORK/value"
  put CODEAPI-EXECUTION-MANIFEST-PRIVATE-KEY "$WORK/value"
  openssl pkey -inform DER -in "$WORK/manifest.der" -pubout -outform DER 2>/dev/null | base64 -w0 > "$WORK/value"
  put SANDBOX-EXECUTION-MANIFEST-PUBLIC-KEY "$WORK/value"
  log "execution-manifest key pair: generated"
fi

# --- The JWT trust, from the chat VM's own key ----------------------------------
az keyvault secret show --vault-name "$CHAT_VAULT" --name CODEAPI-JWT-PRIVATE-JWK-JSON \
  --query value -o tsv > "$WORK/private.jwk"
az keyvault secret show --vault-name "$CHAT_VAULT" --name CODEAPI-JWT-KID --query value -o tsv \
  | tr -d '\n' > "$WORK/kid"
az keyvault secret show --vault-name "$CHAT_VAULT" --name CODEAPI-JWT-SINGLE-TENANT-ID --query value -o tsv \
  | tr -d '\n' > "$WORK/tenant"

# Derive the public key from `d` rather than trusting the stored `x`, and refuse
# if they disagree: a JWK whose x does not match its d signs tokens that nothing
# can verify.
python3 - "$WORK/private.jwk" "$WORK/kid" "$WORK/value" <<'PY'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

jwk = json.load(open(sys.argv[1]))
kid = open(sys.argv[2]).read()
b64d = lambda s: base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
b64e = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
x = b64e(Ed25519PrivateKey.from_private_bytes(b64d(jwk['d'])).public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw))
if jwk.get('x') != x:
    sys.exit("the chat VM's private JWK has an x that does not match its d; fix that first")
if jwk.get('kid') != kid:
    sys.exit("CODEAPI-JWT-KID does not match the kid inside CODEAPI-JWT-PRIVATE-JWK-JSON")
json.dump({'keys': [{'kty': 'OKP', 'crv': 'Ed25519', 'alg': 'EdDSA', 'kid': kid, 'x': x}]},
          open(sys.argv[3], 'w'), separators=(',', ':'))
PY
put CODEAPI-JWT-JWKS-JSON "$WORK/value"
put CODEAPI-JWT-KID "$WORK/kid"
put CODEAPI-JWT-SINGLE-TENANT-ID "$WORK/tenant"
log "JWT trust: public key, kid and tenant derived from $CHAT_VAULT"

printf '%s' "$DOMAIN" > "$WORK/value";     put CODE-DOMAIN "$WORK/value"
printf '%s' "$ACME_EMAIL" > "$WORK/value"; put ACME-EMAIL "$WORK/value"
log "CODE-DOMAIN and ACME-EMAIL set"

log "done. Next, on the interpreter VM: sudo /srv/codeinterpreter/app/scripts/codeinterpreter-deploy.sh --force"
