#!/usr/bin/env bash
#
# Check that the configuration in this repository is internally consistent.
#
#     scripts/validate-config.sh
#
# Run by .github/workflows/validate.yml on every pull request, and safe to run
# locally. Needs yq, jq and docker.
#
# What it is really for: most of what can go wrong in this repository fails at
# REQUEST time rather than at startup, so neither a running instance nor a
# passing deploy tells you anything. An agent pointing at a provider name that
# is off by one space works perfectly until somebody uses it. This script is
# where those get caught.
#
# It also validates the storage path that Maryland Legal Aid does NOT run.
# Dogfooding protects the configuration we use every day; nothing protects the
# other one except a check like this.
#

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FIXTURE_ENV="scripts/fixtures/ci.env"
FAILURES=0

# `docker compose config` insists that every `env_file:` referenced by a service
# actually exists — and it should, because on a real host a missing .env means a
# misconfigured stack. Here there is no .env and there must never be one in git,
# so stand a placeholder up for the duration and take it away afterwards. An
# existing .env (someone running this on a real host) is left strictly alone.
CREATED_PLACEHOLDER_ENV=false
if [ ! -f .env ]; then
  cp "$FIXTURE_ENV" .env
  CREATED_PLACEHOLDER_ENV=true
fi
cleanup() {
  [ "$CREATED_PLACEHOLDER_ENV" = true ] && rm -f "$REPO_ROOT/.env"
}
trap cleanup EXIT

# yq v4 has no `index()` function, so membership is tested by listing the array
# and matching a whole line. Writing this as `yq -e '... | index(...)'` looks
# correct, exits non-zero because the EXPRESSION is invalid rather than because
# the item is absent, and therefore reports "not present" for everything —
# including when the thing you are guarding against IS present.
yaml_array_contains() {
  local file="$1" path="$2" needle="$3"
  yq -r "${path}[]" "$file" 2>/dev/null | grep -Fxq "$needle"
}

pass()  { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*"; FAILURES=$((FAILURES + 1)); }
group() { echo ""; echo "== $* =="; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "validate-config.sh needs '$1' on PATH"; exit 2; }
}
need yq
need jq

STORAGE_MODES=(disk s3)


# =============================================================================
group "Storage overlays render to valid configuration"
# =============================================================================
# The merge that deploy.sh performs, for every mode, exactly as it performs it.

for mode in "${STORAGE_MODES[@]}"; do
  overlay="config/storage/${mode}.yaml"
  out="$(mktemp)"

  if ! yq eval-all '. as $item ireduce ({}; . * $item)' librechat.yaml "$overlay" > "$out" 2>/dev/null; then
    fail "$mode: the yq merge failed"
    rm -f "$out"
    continue
  fi

  strategy="$(yq -r '.fileStrategy // ""' "$out")"
  version="$(yq -r '.version // ""' "$out")"

  if [ -z "$strategy" ]; then
    fail "$mode: the merged config has no fileStrategy"
  elif [ "$strategy" = "null" ]; then
    fail "$mode: fileStrategy merged to null"
  else
    pass "$mode: fileStrategy = $strategy"
  fi

  # A ${VAR} that survived into this key would be rejected by LibreChat's zod
  # enum at startup. This is the exact mistake config/storage/README.md warns
  # about, so it is worth asserting rather than trusting.
  case "$strategy" in
    *'${'*) fail "$mode: fileStrategy contains an uninterpolated variable — see config/storage/README.md" ;;
  esac

  case "$strategy" in
    local|s3|firebase|azure_blob|cloudfront) ;;
    *) fail "$mode: '$strategy' is not one of LibreChat's supported strategies" ;;
  esac

  [ -n "$version" ] && pass "$mode: schema version = $version" || fail "$mode: no version key survived the merge"

  rm -f "$out"
done


# =============================================================================
group "Compose files parse, in every storage mode and profile combination"
# =============================================================================

PROFILE_SETS=("" "mcp-legalserver" "mcp-letterwriter" "mcp-legalserver,mcp-letterwriter")

for mode in "${STORAGE_MODES[@]}"; do
  compose_overlay="compose.storage.${mode}.yml"

  if [ ! -f "$compose_overlay" ]; then
    fail "$mode: $compose_overlay is missing (config/storage/$mode.yaml exists without it)"
    continue
  fi

  for profiles in "${PROFILE_SETS[@]}"; do
    args=(--env-file "$FIXTURE_ENV" -f compose.yaml -f "$compose_overlay")
    label="$mode / ${profiles:-no profiles}"

    if [ -n "$profiles" ]; then
      IFS=',' read -r -a profile_list <<< "$profiles"
      for profile in "${profile_list[@]}"; do
        args+=(--profile "$profile")
      done
    fi

    if docker compose "${args[@]}" config >/dev/null 2>&1; then
      pass "$label"
    else
      fail "$label"
      docker compose "${args[@]}" config 2>&1 | sed 's/^/      /' | head -10
    fi
  done
done

# The disk overlay must bind-mount uploads; the s3 overlay must not. Getting
# these backwards produces an instance that appears to work and silently writes
# files nowhere useful.
disk_mounts="$(docker compose --env-file "$FIXTURE_ENV" -f compose.yaml -f compose.storage.disk.yml config 2>/dev/null | grep -c '/app/uploads' || true)"
s3_mounts="$(docker compose --env-file "$FIXTURE_ENV" -f compose.yaml -f compose.storage.s3.yml config 2>/dev/null | grep -c '/app/uploads' || true)"

[ "$disk_mounts" -gt 0 ] && pass "disk overlay bind-mounts uploads" || fail "disk overlay does not bind-mount uploads"
[ "$s3_mounts" -eq 0 ] && pass "s3 overlay does not bind-mount uploads" || fail "s3 overlay bind-mounts uploads, which it must not"


# =============================================================================
group "No container port is exposed beyond localhost, except Caddy's"
# =============================================================================
# The hardening rule that stops the network firewall from being the only thing
# between the internet and the database.

published="$(
  docker compose --env-file "$FIXTURE_ENV" -f compose.yaml -f compose.storage.disk.yml \
    --profile mcp-legalserver --profile mcp-letterwriter config --format json 2>/dev/null \
  | jq -r '.services | to_entries[] | .key as $svc | (.value.ports // [])[] | "\($svc) \(.published) \(.host_ip // "0.0.0.0")"'
)"

while read -r svc port host_ip; do
  [ -n "${svc:-}" ] || continue
  if [ "$svc" = "caddy" ]; then
    pass "caddy publishes $port to the internet (intended — it is the edge)"
  elif [ "$host_ip" = "127.0.0.1" ]; then
    pass "$svc publishes $port on 127.0.0.1 only"
  else
    fail "$svc publishes $port on $host_ip — every service except caddy must bind 127.0.0.1"
  fi
done <<< "$published"

# Nothing that provides a database administration interface belongs in this
# stack. The previous deployment shipped mongo-express on 0.0.0.0.
if docker compose --env-file "$FIXTURE_ENV" -f compose.yaml config 2>/dev/null | grep -qi 'mongo-express'; then
  fail "mongo-express is present — it must not be"
else
  pass "no mongo-express"
fi


# =============================================================================
group "Every provider name resolves to a real endpoint"
# =============================================================================
# The check that catches the failure nothing else catches. A provider string in
# model-map.json must match a built-in endpoint or an endpoints.custom[].name
# BYTE FOR BYTE. A mismatch fails when a user sends a message, not at startup.

BUILTIN_ENDPOINTS=(openAI anthropic google azureOpenAI bedrock agents assistants)
mapfile -t CUSTOM_ENDPOINTS < <(yq -r '.endpoints.custom[]?.name' librechat.yaml)

for name in "${CUSTOM_ENDPOINTS[@]}"; do
  pass "custom endpoint declared: '$name'"
done

known_endpoint() {
  local candidate="$1" known
  for known in "${BUILTIN_ENDPOINTS[@]}"; do
    [ "$candidate" = "$known" ] && return 0
  done
  for known in "${CUSTOM_ENDPOINTS[@]}"; do
    [ "$candidate" = "$known" ] && return 0
  done
  return 1
}

while IFS= read -r provider; do
  [ -n "$provider" ] || continue
  if known_endpoint "$provider"; then
    pass "model-map.json provider '$provider' resolves"
  else
    fail "model-map.json provider '$provider' matches no built-in or custom endpoint"
  fi
done < <(jq -r 'to_entries[] | select(.key | startswith("_") | not) | .value.provider' scripts/model-map.json | sort -u)

while IFS= read -r endpoint; do
  [ -n "$endpoint" ] || continue
  if known_endpoint "$endpoint"; then
    pass "modelSpecs entry endpoint '$endpoint' resolves"
  else
    fail "modelSpecs entry endpoint '$endpoint' matches no built-in or custom endpoint"
  fi
done < <(yq -r '.modelSpecs.list[]?.preset.endpoint' librechat.yaml | sort -u)


# =============================================================================
group "The approved model list agrees with what is actually configured"
# =============================================================================
# APPROVED_MODELS drives the migration and its verification query. If it drifts
# from the models the application actually offers, the migration will happily
# move agents onto a model nobody can select.

approved="$(node -e "console.log(require('./scripts/lib/agent-model-migration.js').APPROVED_MODELS.join('\n'))" | sort)"
configured="$(
  {
    grep '^ANTHROPIC_MODELS=' env.defaults | cut -d= -f2- | tr ',' '\n'
    grep '^OPENAI_MODELS='    env.defaults | cut -d= -f2- | tr ',' '\n'
    yq -r '.endpoints.custom[]?.models.default[]?' librechat.yaml
  } | sed '/^$/d' | sort -u
)"

if [ "$approved" = "$configured" ]; then
  pass "approved list matches the configured models exactly"
else
  fail "approved list and configured models differ"
  echo "      only in APPROVED_MODELS: $(comm -23 <(echo "$approved") <(echo "$configured") | tr '\n' ' ')"
  echo "      only in configuration:   $(comm -13 <(echo "$approved") <(echo "$configured") | tr '\n' ' ')"
fi

# The built-in openAI endpoint was DELETED on 2026-07-30 (see librechat.yaml).
# Every OpenAI model now reaches users only through the custom endpoint, which
# forces the Responses API. These three checks assert that state rather than the
# weaker "GPT-5.6 is excluded from OPENAI_MODELS" one they replace — that check
# became vacuous the moment OPENAI_MODELS stopped existing, and a check that
# cannot fail is decoration.
if grep -q '^OPENAI_MODELS=' env.defaults; then
  fail "OPENAI_MODELS is set — the built-in openAI endpoint is retired and must stay retired; see docs/modules/models-gpt56-responses.md"
else
  pass "OPENAI_MODELS is absent (built-in openAI endpoint retired)"
fi

if yq -e '.endpoints.openAI' librechat.yaml >/dev/null 2>&1; then
  fail "librechat.yaml declares endpoints.openAI — the built-in endpoint is retired; it is a bypass route around the forced Responses API"
else
  pass "librechat.yaml does not declare the built-in openAI endpoint"
fi

if yaml_array_contains librechat.yaml '.modelSpecs.addedEndpoints' 'openAI'; then
  fail "modelSpecs.addedEndpoints includes openAI — that lets a user bypass the forced Responses API route"
else
  pass "modelSpecs.addedEndpoints excludes the built-in openAI endpoint"
fi

# titleConvo MUST be true on the custom endpoint. When it was false, every
# conversation on every migrated agent was silently saved as "New Chat" —
# agents/title.js early-returns on titleConvo === false with no fallback. Direct
# chats titled fine throughout, so nothing in a normal smoke test caught it.
title_convo="$(yq -r '.endpoints.custom[] | select(.name == "OpenAI GPT-5.6 Responses") | .titleConvo' librechat.yaml 2>/dev/null)"
if [ "$title_convo" = "true" ]; then
  pass "custom endpoint has titleConvo: true (agents get conversation titles)"
else
  fail "custom endpoint titleConvo is '${title_convo:-unset}', must be true — agent conversations will all be saved as \"New Chat\" with no error anywhere"
fi


# =============================================================================
group "MCP overlays are self-consistent and match their Compose profiles"
# =============================================================================
# Each config/mcp/<profile>.yaml is merged in only when <profile> is listed in
# COMPOSE_PROFILES, so a server is declared exactly when it is running. Three
# things can be wrong here, none of which fails at startup:
#
#   - v0.8.7 blocks internal hostnames for MCP URLs by default, and a Compose
#     service name IS an internal hostname. An mcpServers entry without a
#     matching mcpSettings.allowedAddresses line fails every connection.
#   - The URL's host may not be a service in compose.yaml at all.
#   - The service may be a real service carrying a DIFFERENT profile — so the
#     overlay is merged while the container is not running, or the other way
#     round. This is the failure the filename convention exists to prevent, and
#     it is invisible until someone tries to use the tool.

# How many MCP servers a file declares. `// {}` so a file with no mcpServers key
# counts as zero rather than producing "null".
mcp_server_count() { yq -r '.mcpServers // {} | length' "$1"; }

# The base config must NOT declare MCP servers itself. One left behind there
# would be declared unconditionally, which is the whole thing this arrangement
# is for.
if [ "$(mcp_server_count librechat.yaml)" != "0" ]; then
  fail "librechat.yaml declares mcpServers — those belong in config/mcp/<profile>.yaml; see config/mcp/README.md"
else
  pass "librechat.yaml declares no mcpServers of its own"
fi

shopt -s nullglob
MCP_OVERLAYS=(config/mcp/*.yaml)
shopt -u nullglob

[ "${#MCP_OVERLAYS[@]}" -gt 0 ] || fail "config/mcp/ has no overlays at all"

for overlay in "${MCP_OVERLAYS[@]}"; do
  profile="$(basename "$overlay" .yaml)"

  if [ "$(mcp_server_count "$overlay")" = "0" ]; then
    fail "$profile: the overlay declares no mcpServers"
    continue
  fi

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    hostport="$(echo "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
    service="${hostport%%:*}"

    if yaml_array_contains "$overlay" '.mcpSettings.allowedAddresses' "$hostport"; then
      pass "$profile: $hostport is in its own mcpSettings.allowedAddresses"
    else
      fail "$profile: $hostport is NOT in mcpSettings.allowedAddresses — every connection would be refused"
    fi

    if ! yq -e ".services.\"$service\"" compose.yaml >/dev/null 2>&1; then
      fail "$profile: host '$service' has no matching service in compose.yaml"
    elif yaml_array_contains compose.yaml ".services.\"$service\".profiles" "$profile"; then
      pass "$profile: service '$service' carries profile '$profile'"
    else
      fail "$profile: service '$service' exists but does not carry profile '$profile' — the overlay and the container would be enabled by different variables"
    fi
  done < <(yq -r '.mcpServers[]?.url' "$overlay")
done


# =============================================================================
group "Every MCP profile combination renders to valid configuration"
# =============================================================================
# The merge deploy.sh performs, for every combination a deployment might run.
# `*+` appends arrays rather than replacing them: with the bare `*`, two
# overlays each contributing one allowedAddresses entry would leave only the
# last, and the other server would be silently unreachable.

for profiles in "${PROFILE_SETS[@]}"; do
  layers=(librechat.yaml config/storage/disk.yaml)
  label="${profiles:-no profiles}"
  expected=0

  if [ -n "$profiles" ]; then
    IFS=',' read -r -a profile_list <<< "$profiles"
    for profile in "${profile_list[@]}"; do
      overlay="config/mcp/${profile}.yaml"
      if [ -f "$overlay" ]; then
        layers+=("$overlay")
        expected=$((expected + $(mcp_server_count "$overlay")))
      fi
    done
  fi

  out="$(mktemp)"
  if ! yq eval-all '. as $item ireduce ({}; . *+ $item)' "${layers[@]}" > "$out" 2>/dev/null; then
    fail "$label: the yq merge failed"
    rm -f "$out"
    continue
  fi

  # Every declared server's host:port must be in the merged allow list. This is
  # what the append flag is protecting, so assert it on the merged result rather
  # than trusting that deploy.sh still carries the flag.
  merge_ok=true
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    hostport="$(echo "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
    if ! yaml_array_contains "$out" '.mcpSettings.allowedAddresses' "$hostport"; then
      fail "$label: $hostport is declared but absent from the merged allowedAddresses — either its overlay is missing the entry, or the merge is replacing arrays instead of appending them"
      merge_ok=false
    fi
  done < <(yq -r '.mcpServers[]?.url' "$out")

  # Every server the selected overlays declare must survive the merge. A map
  # merge does not lose keys, so this is really a guard against two overlays
  # declaring the SAME server name, where the second would overwrite the first.
  declared="$(mcp_server_count "$out")"

  if [ "$declared" != "$expected" ]; then
    fail "$label: expected $expected declared MCP server(s), found $declared"
    merge_ok=false
  fi

  # With no MCP profile on, the app must see no mcpServers key at all — that is
  # what removes the 60 seconds of failed connections at startup.
  if [ -z "$profiles" ] && [ "$(yq -r 'has("mcpServers")' "$out")" != "false" ]; then
    fail "no profiles: the merged config still has an mcpServers key"
    merge_ok=false
  fi

  [ "$merge_ok" = true ] && pass "$label: $declared MCP server(s) declared, all in the allow list"
  rm -f "$out"
done


# =============================================================================
group "deploy.sh re-executes itself as a continuation, not a fresh decision"
# =============================================================================
# When an update changes deploy.sh, the running script re-execs the new copy. By
# then the checkout has already been fast-forwarded, so the replacement process
# would find PREVIOUS_SHA == CURRENT_SHA, conclude it is already up to date, and
# exit 0 without deploying anything. It must therefore be handed --force.
#
# This shipped without it once. The symptom is the worst kind: the checkout
# advances, the log says "already up to date; nothing to do", the deploy reports
# success, and the change never applies — so every commit that touches deploy.sh
# silently declines to deploy itself. There is no way to catch that in CI by
# running the script (it wants Docker, a Key Vault and a mounted data disk), so
# the invariant is asserted directly.

reexec_line="$(grep -n 'exec .*--reexeced' scripts/deploy.sh || true)"

if [ -z "$reexec_line" ]; then
  fail "deploy.sh has no --reexeced self-exec; if that mechanism was removed on purpose, remove this check too"
elif ! echo "$reexec_line" | grep -q -- '--force'; then
  fail "deploy.sh re-execs itself WITHOUT --force — the new process will decide it is already up to date and exit without deploying"
  echo "      $reexec_line"
# The original bug passed --force CONDITIONALLY, as
# $([ "$FORCE" = true ] && echo --force). That still contains the literal
# --force, so testing only for the flag's presence accepts the broken form —
# which is exactly the mistake this check exists to catch. Any mention of the
# FORCE variable on this line means the flag is conditional on how the script was
# invoked, and the systemd timer never invokes it with --force.
elif echo "$reexec_line" | grep -q 'FORCE'; then
  fail "deploy.sh passes --force to its re-exec conditionally, on \$FORCE — the timer never sets that, so a timer-triggered update would advance the checkout and skip the deploy"
  echo "      $reexec_line"
else
  pass "the re-exec passes --force unconditionally (line ${reexec_line%%:*})"
fi


# =============================================================================
group "DATA_DIR agrees between env.defaults and the Bicep template"
# =============================================================================
# cloud-init mounts the disk at the Bicep value; the containers bind-mount from
# the env.defaults value. If they disagree the stack starts on an empty
# directory on the OS disk and looks fine.

env_data_dir="$(grep '^DATA_DIR=' env.defaults | cut -d= -f2-)"
bicep_data_dir="$(grep -oP "param dataDir string = '\K[^']+" infra/main.bicep)"

if [ "$env_data_dir" = "$bicep_data_dir" ]; then
  pass "DATA_DIR = $env_data_dir in both"
else
  fail "DATA_DIR differs: env.defaults='$env_data_dir' but main.bicep='$bicep_data_dir'"
fi


# =============================================================================
group "The committed ARM template matches the Bicep source"
# =============================================================================
# infra/main.json is what the "Deploy to Azure" button reads. If it lags behind
# main.bicep, the portal deploys yesterday's infrastructure and nothing says so.

if command -v az >/dev/null 2>&1; then
  regenerated="$(mktemp)"
  if az bicep build --file infra/main.bicep --outfile "$regenerated" >/dev/null 2>&1; then
    # walk(), not a top-level del(): nested modules embed their own _generator
    # block deeper in the JSON, so stripping only the outer one still compares
    # Bicep CLI versions between whoever built the file and whoever checks it.
    strip_gen() { jq -S 'walk(if type == "object" then del(._generator) else . end)' "$1"; }
    if diff -q <(strip_gen infra/main.json) <(strip_gen "$regenerated") >/dev/null; then
      pass "infra/main.json is in sync with infra/main.bicep"
    else
      fail "infra/main.json is stale — run: az bicep build --file infra/main.bicep --outfile infra/main.json"
    fi
  else
    fail "az bicep build failed"
  fi
  rm -f "$regenerated"
else
  echo "  – skipped (az not installed)"
fi


# =============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All configuration checks passed."
  exit 0
fi
echo "$FAILURES check(s) failed."
exit 1
