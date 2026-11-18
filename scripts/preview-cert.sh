#!/usr/bin/env bash
#
# Obtain or renew the wildcard certificate for the self-hosted Sandpack
# previews (compose.previews.yml, UPGRADE_PLAN Round 2 gate D16).
#
#   preview-cert.sh             get or renew; reload Caddy if the cert changed
#   preview-cert.sh --no-reload get or renew only (deploy.sh, before starting)
#
# Exits 0 when previews are off (no PREVIEW_DOMAIN), or when a certificate with
# more than MIN_DAYS left is on disk afterwards. A failed renewal with a
# still-valid certificate is a warning, not a failure: previews keep working
# and the timer tries again tomorrow. Exits 1 only when there is no usable
# certificate, and deploy.sh then leaves previews off for that deploy.
#
# How: lego, as a one-shot container on the HOST network, solves the ACME
# DNS-01 challenge in the Azure DNS zone named PREVIEW_DOMAIN using the VM's
# managed identity. The identity needs DNS Zone Contributor on that zone only.
# Host networking is what lets it reach the instance metadata endpoint, which
# scripts/container-imds-guard.sh blocks for ordinary (bridged) containers.
# No credential is stored anywhere.
#
# Settings, from .env (rendered from Key Vault):
#   PREVIEW_DOMAIN       the zone; empty or absent means previews are off
#   ACME_EMAIL           Let's Encrypt contact, shared with Caddy
#   PREVIEW_ACME_SERVER  optional; e.g. Let's Encrypt staging for a rehearsal
#   DATA_DIR             optional; default /srv/librechat/data

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "preview-cert.sh must run as root" >&2
  exit 1
fi

# Pinned: renovate.json's custom manager keeps this current.
LEGO_IMAGE="goacme/lego:v5.6.0@sha256:6f1583fc026a455ea46a7a5858c576105bb69c2e2de69db391cab7f14750350c"
MIN_DAYS=7

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
RELOAD=true
[ "${1:-}" = "--no-reload" ] && RELOAD=false

log() { echo "[preview-cert $(date -u +%H:%M:%S)] $*"; }

env_value() {
  [ -f "$ENV_FILE" ] || return 0
  grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true
}

DOMAIN="$(env_value PREVIEW_DOMAIN)"
if [ -z "$DOMAIN" ]; then
  log "PREVIEW_DOMAIN is not set; previews are off, nothing to do"
  exit 0
fi
case "$DOMAIN" in
  *[!a-z0-9.-]*|.*|*.) log "PREVIEW_DOMAIN '$DOMAIN' is not a plain DNS name"; exit 1 ;;
esac

EMAIL="$(env_value ACME_EMAIL)"
SERVER="$(env_value PREVIEW_ACME_SERVER)"
SERVER="${SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
DATA_DIR="$(env_value DATA_DIR)"
DATA_DIR="${DATA_DIR:-/srv/librechat/data}"
STORE="$DATA_DIR/preview-tls"
CERT="$STORE/certificates/_.$DOMAIN.crt"

install -d -m 0700 "$STORE"

imds() {
  curl -fsS -m 5 -H Metadata:true \
    "http://169.254.169.254/metadata/instance/compute/$1?api-version=2021-02-01&format=text"
}

cert_ok() {
  [ -f "$CERT" ] && openssl x509 -in "$CERT" -noout -checkend $((MIN_DAYS * 86400)) >/dev/null 2>&1
}

before="$(sha256sum "$CERT" 2>/dev/null | cut -d' ' -f1 || true)"

log "requesting or renewing *.$DOMAIN"
if docker run --rm --network host \
     -v "$STORE:/data" \
     -e AZURE_AUTH_METHOD=msi \
     -e AZURE_SUBSCRIPTION_ID="$(imds subscriptionId)" \
     -e AZURE_RESOURCE_GROUP="$(imds resourceGroupName)" \
     -e AZURE_ZONE_NAME="$DOMAIN" \
     -e LEGO_EMAIL="$EMAIL" \
     "$LEGO_IMAGE" run --path /data --accept-tos --server "$SERVER" \
       --dns azuredns -d "*.$DOMAIN" -d "$DOMAIN"; then
  log "lego finished"
else
  log "WARNING: lego failed"
fi

if ! cert_ok; then
  log "ERROR: no certificate for *.$DOMAIN valid for more than $MIN_DAYS days"
  exit 1
fi

after="$(sha256sum "$CERT" | cut -d' ' -f1)"
log "certificate valid until $(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)"

if [ "$before" != "$after" ] && [ "$RELOAD" = true ] \
   && docker ps --format '{{.Names}}' | grep -qx caddy; then
  # The certificates are a directory mount, so the new files are visible;
  # --force makes Caddy load them although its config is unchanged.
  log "certificate changed; reloading Caddy"
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force
fi
