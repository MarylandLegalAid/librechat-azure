#!/usr/bin/env bash
#
# Check that the configuration is COMPLETE, not just that it parses.
#
#     scripts/check-secrets.sh                    # against env.defaults + Key Vault
#     scripts/check-secrets.sh --env-file .env    # against an already-rendered .env
#     scripts/check-secrets.sh --vault kv-name    # a specific vault
#
# Read-only. It never writes anything, and it never prints a secret's value —
# only whether one is present, and for a few variables a derived fact such as a
# length or a leading character.
#
# WHY THIS EXISTS
#
# scripts/validate-config.sh checks the files in this repository. Nothing checked
# the secrets, and the secrets are where a deployment goes wrong quietly. Every
# variable here is optional as far as the application is concerned: it starts
# happily without them, reports itself healthy, and fails only when somebody uses
# the feature.
#
# The case that prompted this: OPENID_CALLBACK_URL was never seeded. LibreChat
# composes its redirect as DOMAIN_SERVER + OPENID_CALLBACK_URL, so the absent
# value concatenated the literal string "undefined" and every sign-in died at
# Entra with AADSTS50011 and a redirect URI ending "...mdlab.orgundefined". The
# stack was green throughout. Nobody could log in.
#
# So the checks below are organized by FEATURE. A feature is switched on by a
# trigger variable; when it is on, its companions stop being optional. That is
# the only way to tell "not configured" apart from "half configured", and half
# configured is the state that hurts.
#

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE=""
VAULT_NAME="${KV_NAME:-}"
CONFIG_FILE="${CONFIG_FILE:-/etc/librechat-deploy.conf}"

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --vault)    VAULT_NAME="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-secrets.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

FAILURES=0
WARNINGS=0

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  ! $*"; WARNINGS=$((WARNINGS + 1)); }
group() { echo ""; echo "== $* =="; }

declare -A values=()

# -----------------------------------------------------------------------------
# Load the effective configuration, exactly as render-env.sh assembles it.
# -----------------------------------------------------------------------------
# env.defaults first, then Key Vault on top. Checking only the vault would report
# variables as missing when env.defaults already supplies them; checking only
# env.defaults would miss everything real. The merge is the thing that runs.
load_file() {
  local file="$1" line name
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"
    [ -n "$name" ] || continue
    values["$name"]="${line#*=}"
  done < "$file"
}

if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "check-secrets.sh: no such file: $ENV_FILE" >&2; exit 2; }
  load_file "$ENV_FILE"
  echo "Source: $ENV_FILE (${#values[@]} variables)"
else
  [ -f env.defaults ] && load_file env.defaults

  # shellcheck disable=SC1090
  [ -z "$VAULT_NAME" ] && [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE" && VAULT_NAME="${KV_NAME:-}"

  if [ -z "$VAULT_NAME" ]; then
    echo "check-secrets.sh: no Key Vault name." >&2
    echo "  Pass --vault NAME, set KV_NAME, or check a rendered file with --env-file." >&2
    echo "  On a workstation:" >&2
    echo "    az keyvault list -g <rg> --query \"[?starts_with(name,'kv-')].name | [0]\" -o tsv" >&2
    exit 2
  fi

  command -v az >/dev/null 2>&1 || { echo "check-secrets.sh needs 'az' on PATH"; exit 2; }

  # Names only. Presence is what most checks need, and one list call beats one
  # show call per secret. Values are fetched below for the few that need their
  # shape inspected.
  names="$(az keyvault secret list --vault-name "$VAULT_NAME" \
             --query "[?attributes.enabled].name" -o tsv 2>/dev/null)" || {
    echo "check-secrets.sh: cannot list secrets in '$VAULT_NAME'." >&2
    echo "  Wrong vault name, or you lack 'Key Vault Secrets User' on it." >&2
    exit 2
  }

  vault_count=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in BOOTSTRAP-*) continue ;; esac   # host-only, never in .env
    values["${n//-/_}"]="<present>"
    vault_count=$((vault_count + 1))
  done <<< "$names"

  # The handful whose SHAPE matters. Fetched individually and never printed.
  for v in COMPOSE_PROFILES FILE_STORAGE OPENID_CALLBACK_URL DOMAIN_CLIENT \
           DOMAIN_SERVER CREDS_KEY CREDS_IV LIBRECHAT_CODE_BASEURL \
           DOCUMENT_OCR_PROVIDER; do
    if [ "${values[$v]:-}" = "<present>" ]; then
      values["$v"]="$(az keyvault secret show --vault-name "$VAULT_NAME" \
                        --name "${v//_/-}" --query value -o tsv 2>/dev/null)"
    fi
  done

  echo "Source: env.defaults + Key Vault '$VAULT_NAME' ($vault_count secrets)"
fi

# A variable counts as set only if it is non-empty after trimming. COMPOSE_PROFILES
# was once literally " ", which is absent for every practical purpose but present
# to any test that only asks whether the key exists.
is_set() {
  local v="${values[$1]:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  [ -n "$v" ]
}
value_of() { echo "${values[$1]:-}"; }

require() {
  local feature="$1"; shift
  local missing=()
  for v in "$@"; do is_set "$v" || missing+=("$v"); done
  if [ ${#missing[@]} -eq 0 ]; then
    pass "$feature: all required variables present"
  else
    fail "$feature: missing ${missing[*]}"
  fi
}

advise() {
  local feature="$1" note="$2"; shift 2
  local missing=()
  for v in "$@"; do is_set "$v" || missing+=("$v"); done
  [ ${#missing[@]} -eq 0 ] && pass "$feature: optional extras present" \
                           || warn "$feature: ${missing[*]} — $note"
}

# All-or-nothing: some of one, none of the other, is a silent no-op.
all_or_nothing() {
  local label="$1"; shift
  local set_count=0
  for v in "$@"; do is_set "$v" && set_count=$((set_count + 1)); done
  if [ "$set_count" -eq 0 ]; then
    pass "$label: not configured (consistent)"
  elif [ "$set_count" -eq $# ]; then
    pass "$label: fully configured"
  else
    fail "$label: $set_count of $# set — a partial group is ignored entirely, silently"
  fi
}


# =============================================================================
group "Core — required by every deployment"
# =============================================================================
require "core" CREDS_KEY CREDS_IV JWT_SECRET JWT_REFRESH_SECRET \
                MEILI_MASTER_KEY ADMIN_PANEL_SESSION_SECRET \
                DOMAIN_CLIENT DOMAIN_SERVER

if ! is_set ANTHROPIC_API_KEY && ! is_set OPENAI_API_KEY; then
  fail "core: no model provider key (ANTHROPIC_API_KEY or OPENAI_API_KEY)"
else
  pass "core: at least one model provider key is present"
fi


# =============================================================================
group "Shapes that fail silently when wrong"
# =============================================================================
# Only reached when values are available — i.e. not in vault-presence-only mode
# for variables that were not fetched.

check_hex_length() {
  local name="$1" want="$2" v; v="$(value_of "$name")"
  [ -n "$v" ] && [ "$v" != "<present>" ] || return 0
  if [ "${#v}" -ne "$want" ]; then
    fail "$name is ${#v} characters, expected $want — every stored user API key becomes undecryptable"
  elif ! echo "$v" | grep -qE '^[0-9a-fA-F]+$'; then
    fail "$name is not hexadecimal"
  else
    pass "$name is $want hex characters"
  fi
}
check_hex_length CREDS_KEY 64
check_hex_length CREDS_IV  32

for d in DOMAIN_CLIENT DOMAIN_SERVER; do
  v="$(value_of "$d")"
  [ -n "$v" ] && [ "$v" != "<present>" ] || continue
  case "$v" in
    http://*|https://*)
      case "$v" in
        */) fail "$d ends with a slash — paths are appended directly and would double it" ;;
        *)  pass "$d looks well formed" ;;
      esac ;;
    *) fail "$d has no scheme; it must start with https://" ;;
  esac
done

# The exact bug this script was written for.
if is_set OPENID_CALLBACK_URL; then
  v="$(value_of OPENID_CALLBACK_URL)"
  if [ "$v" = "<present>" ]; then
    pass "OPENID_CALLBACK_URL is set"
  else
    case "$v" in
      http://*|https://*) fail "OPENID_CALLBACK_URL is a full URL; it must be a path like /oauth/openid/callback, because DOMAIN_SERVER is prepended" ;;
      /*) pass "OPENID_CALLBACK_URL is a path: $v" ;;
      *)  fail "OPENID_CALLBACK_URL must begin with '/' — it is appended to DOMAIN_SERVER" ;;
    esac
  fi
fi


# =============================================================================
group "Single sign-on"
# =============================================================================
if is_set OPENID_CLIENT_ID; then
  # OPENID_CALLBACK_URL is the one that was missing. Without it LibreChat sends a
  # redirect URI ending in the literal text "undefined" and the provider rejects
  # every sign-in — with the application otherwise perfectly healthy.
  require "sso" OPENID_CLIENT_SECRET OPENID_ISSUER OPENID_SESSION_SECRET OPENID_CALLBACK_URL
else
  pass "sso: not configured (email + password login)"
fi

all_or_nothing "sso admin role" \
  OPENID_ADMIN_ROLE OPENID_ADMIN_ROLE_PARAMETER_PATH OPENID_ADMIN_ROLE_TOKEN_KIND
all_or_nothing "sso required role" \
  OPENID_REQUIRED_ROLE OPENID_REQUIRED_ROLE_PARAMETER_PATH OPENID_REQUIRED_ROLE_TOKEN_KIND


# =============================================================================
group "Code interpreter"
# =============================================================================
if is_set LIBRECHAT_CODE_BASEURL; then
  require "code interpreter" CODEAPI_AUTH_PROVIDER CODEAPI_JWT_PRIVATE_JWK_JSON \
                             CODEAPI_JWT_ALGORITHM CODEAPI_JWT_ISSUER \
                             CODEAPI_JWT_AUDIENCE CODEAPI_JWT_KID
elif is_set CODEAPI_JWT_PRIVATE_JWK_JSON; then
  fail "code interpreter: CODEAPI_* secrets exist but LIBRECHAT_CODE_BASEURL is unset, so none of them are used"
else
  pass "code interpreter: not configured"
fi


# =============================================================================
group "File storage"
# =============================================================================
storage="$(value_of FILE_STORAGE)"; storage="${storage:-disk}"
if [ "$storage" = "s3" ]; then
  require "storage (s3)" AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET_NAME AWS_REGION
else
  pass "storage: $storage"
  # Legacy S3 records keep serving from the bucket even on disk storage, so the
  # credentials staying set is deliberate, not leftover.
  is_set AWS_ACCESS_KEY_ID && pass "storage: AWS credentials retained for pre-migration s3 file records"
fi


# =============================================================================
group "MCP servers (per enabled Compose profile)"
# =============================================================================
profiles="$(value_of COMPOSE_PROFILES)"
if ! is_set COMPOSE_PROFILES; then
  pass "mcp: no profiles enabled"
else
  pass "mcp: profiles = $profiles"
  case ",$profiles," in
    *,mcp-legalserver,*)
      require "mcp-legalserver" LEGALSERVER_BASE_URL LEGALSERVER_BEARER_TOKEN
      # Optional to the server — it starts and advertises every tool without
      # them — but the current-user tools fail when somebody calls them.
      advise "mcp-legalserver" "the my-tasks / my-matters / my-calendar tools fail at call time without these" \
        LEGALSERVER_CURRENT_USER_TASKS_REPORT_URL \
        LEGALSERVER_CURRENT_USER_MATTERS_REPORT_URL \
        LEGALSERVER_CURRENT_USER_EVENTS_REPORT_URL

      # OCR is the trigger-and-companions pattern again, except which companion
      # is required depends on the trigger's VALUE rather than just its presence
      # — so DOCUMENT_OCR_PROVIDER is one of the few secrets fetched in full
      # above. Empty and `none` both mean off, which is a complete state, not a
      # half-configured one.
      #
      # This deployment leaves OCR off deliberately — every provider sends page
      # images of client documents to a third party, and local OCR does not fit
      # this VM's CPU budget. The checks below exist for whoever decides
      # otherwise: a half-configured provider should fail here rather than on the
      # first scanned page. See docs/modules/mcp-legalserver.md.
      ocr_provider="$(value_of DOCUMENT_OCR_PROVIDER)"
      case "$ocr_provider" in
        ''|none)
          pass "mcp-legalserver: OCR off — document tools read native-digital PDFs only"
          ;;
        openai)
          # Already required by the core check, but only because ANTHROPIC_API_KEY
          # is the alternative there. An Anthropic-only deployment passes core and
          # would land here with no key at all.
          require "mcp-legalserver OCR (openai)" OPENAI_API_KEY
          ;;
        openrouter)
          require "mcp-legalserver OCR (openrouter)" OPENROUTER_API_KEY
          ;;
        vertex_gemini)
          require "mcp-legalserver OCR (vertex_gemini)" GOOGLE_CLOUD_PROJECT
          # Application Default Credentials need a file the container can open.
          # legalserver-mcp declares no volumes, so unless compose.yaml has been
          # changed to mount one, this path resolves to nothing and every OCR
          # call fails while the server itself stays healthy.
          if is_set GOOGLE_APPLICATION_CREDENTIALS; then
            warn "mcp-legalserver: vertex_gemini reads a service-account FILE at GOOGLE_APPLICATION_CREDENTIALS — confirm compose.yaml mounts it into legalserver-mcp, which declares no volumes by default"
          else
            fail "mcp-legalserver: vertex_gemini has no credentials — set GOOGLE_APPLICATION_CREDENTIALS and mount the file into legalserver-mcp"
          fi
          ;;
        *)
          fail "mcp-legalserver: DOCUMENT_OCR_PROVIDER='$ocr_provider' is not one of openai, openrouter, vertex_gemini, none"
          ;;
      esac

      # An explicit model overrides the provider's own default, and nothing
      # checks that the two belong together until a page is sent.
      case "$ocr_provider" in
        ''|none) ;;
        *) is_set DOCUMENT_OCR_MODEL \
             && warn "mcp-legalserver: DOCUMENT_OCR_MODEL is set — confirm that model exists on '$ocr_provider', or unset it to take that provider's default" \
             || pass "mcp-legalserver: OCR model left to the provider's default" ;;
      esac
      ;;
  esac
  case ",$profiles," in
    *,mcp-letterwriter,*)
      # LETTERHEAD_DIR is set in compose.yaml, not here, so it is not required.
      require "mcp-letterwriter" ORGANIZATION_NAME
      ;;
  esac
fi


# =============================================================================
group "Outbound email"
# =============================================================================
# Wholly absent is fine under SSO-only login. Partially set is not: LibreChat
# will try to send and fail.
all_or_nothing "email" EMAIL_HOST EMAIL_PORT EMAIL_USERNAME EMAIL_PASSWORD


# =============================================================================
echo ""
if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "Configuration is complete."
  exit 0
fi
[ "$WARNINGS" -gt 0 ] && echo "$WARNINGS warning(s) — a feature is degraded but the deployment works."
if [ "$FAILURES" -eq 0 ]; then
  exit 0
fi
echo "$FAILURES problem(s) — each one breaks a feature that reports itself healthy."
exit 1
