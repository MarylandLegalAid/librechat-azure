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

  # A section left holding only comments (say `fileConfig:` after its last key
  # is deleted) is YAML null, and LibreChat refuses to start on it. Staging hit
  # exactly this on 2026-10-15 and rolled back.
  null_keys="$(yq -r 'to_entries[] | select(.value == null) | .key' "$out")"
  if [ -n "$null_keys" ]; then
    fail "$mode: top-level key(s) with no value (YAML null): $(echo "$null_keys" | tr '\n' ' ')"
  else
    pass "$mode: no top-level key is empty"
  fi

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
group "Every container has bounded JSON logs"
# =============================================================================
# Docker's json-file driver grows forever unless both limits are set. Check the
# rendered alias on every service so adding one without the shared policy fails
# before it reaches a host.

while IFS=$'\t' read -r service driver max_size max_file; do
  if [ "$driver" = "json-file" ] && [ "$max_size" = "10m" ] && [ "$max_file" = "5" ]; then
    pass "$service logs are bounded at 10m × 5"
  else
    fail "$service logging is '$driver / $max_size / $max_file', expected 'json-file / 10m / 5'"
  fi
done < <(
  yq -r '.services | to_entries[] | [.key, .value.logging.driver, .value.logging.options."max-size", .value.logging.options."max-file"] | @tsv' compose.yaml
)


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

# conversation-map.json: a target that names an endpoint, spec or model the
# configuration does not have would move conversations somewhere they cannot
# be continued. The migration's own checks cannot see librechat.yaml, so this
# is the only place that catches it.
mapfile -t SPEC_NAMES < <(yq -r '.modelSpecs.list[]?.name' librechat.yaml)
approved_models="$(node -e "console.log(require('./scripts/lib/agent-model-migration.js').APPROVED_MODELS.join('\n'))")"
while IFS=$'\t' read -r target endpoint model spec; do
  [ -n "$target" ] || continue
  if ! known_endpoint "$endpoint"; then
    fail "conversation-map.json target '$target': endpoint '$endpoint' matches no built-in or custom endpoint"
  elif ! grep -qxF "$model" <<< "$approved_models"; then
    fail "conversation-map.json target '$target': model '$model' is not an approved, configured model"
  elif [ -n "$spec" ] && ! printf '%s\n' "${SPEC_NAMES[@]}" | grep -qxF "$spec"; then
    fail "conversation-map.json target '$target': spec '$spec' is not a modelSpecs entry"
  else
    pass "conversation-map.json target '$target' resolves"
  fi
done < <(jq -r '.targets | to_entries[] | select(.key | startswith("_") | not)
                | [.key, .value.endpoint, .value.model, (.value.spec // "")] | @tsv' scripts/conversation-map.json)

# conversation-map.json specs: a favorite moved onto a spec that does not exist
# would pin nothing. A retired spec still in the config would never be retired.
while IFS=$'\t' read -r from to; do
  [ -n "$from" ] || continue
  if ! printf '%s\n' "${SPEC_NAMES[@]}" | grep -qxF "$to"; then
    fail "conversation-map.json spec '$from' -> '$to': '$to' is not a modelSpecs entry"
  elif printf '%s\n' "${SPEC_NAMES[@]}" | grep -qxF "$from"; then
    fail "conversation-map.json retires spec '$from', but modelSpecs still has it"
  else
    pass "conversation-map.json spec '$from' -> '$to' resolves"
  fi
done < <(jq -r '(.specs // {}) | to_entries[] | select(.key | startswith("_") | not) | [.key, .value] | @tsv' scripts/conversation-map.json)

# conversation-map.json targets on a spec: the server applies a preset only under
# modelSpecs.enforce, so a moved conversation runs on whatever it stores. Every
# setting the spec's preset declares must be stored with the same value, or the
# moved conversation quietly differs from one the user starts on that preset.
while IFS=$'\t' read -r target spec field want; do
  [ -n "$target" ] || continue
  got="$(jq -c --arg t "$target" --arg f "$field" '.targets[$t][$f]' scripts/conversation-map.json)"
  if [ "$got" = "$want" ]; then
    pass "conversation-map.json target '$target' has spec '$spec' $field $want"
  else
    fail "conversation-map.json target '$target': $field is $got, but spec '$spec' sets $want"
  fi
done < <(jq -r '.targets | to_entries[] | select(.key | startswith("_") | not)
                | select(.value.spec != null) | [.key, .value.spec] | @tsv' scripts/conversation-map.json \
  | while IFS=$'\t' read -r target spec; do
      SPEC="$spec" yq -o=json -I=0 '.modelSpecs.list[] | select(.name == strenv(SPEC)) | .preset | to_entries[]
          | select(.key != "promptPrefix" and .key != "instructions" and .key != "greeting")' librechat.yaml \
        | jq -r --arg t "$target" --arg s "$spec" '[$t, $s, .key, (.value | tojson)] | @tsv'
    done)

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

# A custom endpoint is HIDDEN (retired) when nobody can choose it: there is a
# modelSpecs list, the endpoint is not in modelSpecs.addedEndpoints, no spec
# points at it, agents.allowedProviders exists and leaves it out, and the memory
# agent does not use it. A hidden endpoint stays declared only so references
# the migrations have not moved yet still resolve, so its models are not
# "offered" and do not belong in the approved list.
spec_count="$(yq -r '.modelSpecs.list | length' librechat.yaml 2>/dev/null)"
allowed_providers_set="$(yq -r '.endpoints.agents | has("allowedProviders")' librechat.yaml 2>/dev/null)"
memory_provider="$(yq -r '.memory.agent.provider // ""' librechat.yaml)"
custom_hidden() {
  local name="$1"
  [ "${spec_count:-0}" -gt 0 ] || return 1
  yaml_array_contains librechat.yaml '.modelSpecs.addedEndpoints' "$name" && return 1
  yq -r '.modelSpecs.list[]?.preset.endpoint' librechat.yaml | grep -qxF "$name" && return 1
  [ "$allowed_providers_set" = "true" ] || return 1
  yaml_array_contains librechat.yaml '.endpoints.agents.allowedProviders' "$name" && return 1
  [ "$memory_provider" != "$name" ] || return 1
  return 0
}

approved="$(node -e "console.log(require('./scripts/lib/agent-model-migration.js').APPROVED_MODELS.join('\n'))" | sort)"
configured="$(
  {
    grep '^ANTHROPIC_MODELS=' env.defaults | cut -d= -f2- | tr ',' '\n'
    grep '^OPENAI_MODELS='    env.defaults | cut -d= -f2- | tr ',' '\n'
    for name in "${CUSTOM_ENDPOINTS[@]}"; do
      custom_hidden "$name" && continue
      yq -r ".endpoints.custom[] | select(.name == \"$name\") | .models.default[]?" librechat.yaml
    done
  } | sed '/^$/d' | sort -u
)"

for name in "${CUSTOM_ENDPOINTS[@]}"; do
  if custom_hidden "$name"; then
    pass "custom endpoint '$name' is hidden (retired: not offered, kept for unmigrated references)"
  fi
done

if [ "$approved" = "$configured" ]; then
  pass "approved list matches the configured models exactly"
else
  fail "approved list and configured models differ"
  echo "      only in APPROVED_MODELS: $(comm -23 <(echo "$approved") <(echo "$configured") | tr '\n' ' ')"
  echo "      only in configuration:   $(comm -13 <(echo "$approved") <(echo "$configured") | tr '\n' ' ')"
fi

# OpenAI models live on the built-in openAI endpoint (UPGRADE_PLAN M13/M14).
# Tool use needs the Responses API, and v0.8.8 sends a model there on its own
# only when it is GPT-6: upstream's GPT6_TIER pattern in
# packages/data-provider (`prefersResponsesApiByModel`). Re-check the pattern at
# every LibreChat upgrade. GPT-5.6 would reach Chat Completions here and fail on
# reasoning plus tools at request time, so OPENAI_MODELS is GPT-6 only.
GPT6_TIER='^gpt-6(\.[0-9]+)?-(astra|sol|luna)(-|$)'
openai_models="$(grep '^OPENAI_MODELS=' env.defaults | cut -d= -f2-)"
if [ -z "$openai_models" ]; then
  # Unset or empty while OPENAI_API_KEY is set = OpenAI's whole catalog.
  fail "OPENAI_MODELS is missing or empty — that allows OpenAI's entire catalog; list the GPT-6 models explicitly"
else
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    if grep -qiE "$GPT6_TIER" <<< "$model"; then
      pass "OPENAI_MODELS entry '$model' is GPT-6 (routed to the Responses API)"
    else
      fail "OPENAI_MODELS entry '$model' is not GPT-6 — v0.8.8 would send it to Chat Completions, where tool use can fail; see docs/modules/models-gpt56-responses.md"
    fi
  done < <(tr ',' '\n' <<< "$openai_models")
fi

if grep -qE '^ENDPOINTS=(.*,)?openAI(,|$)' env.defaults; then
  pass "ENDPOINTS includes the built-in openAI endpoint"
else
  fail "ENDPOINTS does not include openAI, but OpenAI models are configured there"
fi

# No user-reachable custom endpoint may point at first-party OpenAI. It would be
# a second route to OpenAI models, outside OPENAI_MODELS and outside upstream's
# GPT-6 routing. A hidden (retired) one is tolerated until it is deleted.
for name in "${CUSTOM_ENDPOINTS[@]}"; do
  base_url="$(yq -r ".endpoints.custom[] | select(.name == \"$name\") | .baseURL // \"\"" librechat.yaml)"
  if grep -qiE '^https?://api\.openai\.com' <<< "$base_url"; then
    if custom_hidden "$name"; then
      pass "custom endpoint '$name' points at api.openai.com but is hidden (retired)"
    else
      fail "custom endpoint '$name' points at api.openai.com and is reachable — OpenAI models belong on the built-in openAI endpoint"
    fi
  fi
done

# titleConvo MUST be true on the endpoint agents use. When it was false, every
# conversation on every agent was silently saved as "New Chat" —
# agents/title.js early-returns on titleConvo === false with no fallback. Direct
# chats titled fine throughout, so nothing in a normal smoke test caught it.
title_convo="$(yq -r '.endpoints.openAI.titleConvo' librechat.yaml 2>/dev/null)"
if [ "$title_convo" = "true" ]; then
  pass "endpoints.openAI has titleConvo: true (agents get conversation titles)"
else
  fail "endpoints.openAI titleConvo is '${title_convo:-unset}', must be true — agent conversations will all be saved as \"New Chat\" with no error anywhere"
fi

# The title and memory models must be ones their endpoint actually serves.
# Neither failure is visible: titles silently stop, memory silently stops.
anthropic_models="$(grep '^ANTHROPIC_MODELS=' env.defaults | cut -d= -f2-)"
model_served() {
  local provider="$1" model="$2"
  case "$provider" in
    openAI)    tr ',' '\n' <<< "$openai_models"    | grep -qxF "$model" ;;
    anthropic) tr ',' '\n' <<< "$anthropic_models" | grep -qxF "$model" ;;
    *)         yq -r ".endpoints.custom[] | select(.name == \"$provider\") | .models.default[]?" librechat.yaml | grep -qxF "$model" ;;
  esac
}
title_model="$(yq -r '.endpoints.openAI.titleModel // ""' librechat.yaml)"
if [ -n "$title_model" ] && model_served openAI "$title_model"; then
  pass "endpoints.openAI.titleModel '$title_model' is in OPENAI_MODELS"
else
  fail "endpoints.openAI.titleModel '${title_model:-unset}' is not in OPENAI_MODELS — titles would silently stop"
fi
memory_model="$(yq -r '.memory.agent.model // ""' librechat.yaml)"
if known_endpoint "$memory_provider" && model_served "$memory_provider" "$memory_model"; then
  pass "memory agent '$memory_provider' / '$memory_model' resolves"
else
  fail "memory agent '$memory_provider' / '$memory_model' does not resolve — memory extraction would silently stop"
fi
summary_provider="$(yq -r '.summarization.provider // ""' librechat.yaml)"
summary_model="$(yq -r '.summarization.model // ""' librechat.yaml)"
if [ -z "$summary_provider$summary_model" ]; then
  pass "summarization has no provider/model of its own (each chat summarizes itself)"
elif known_endpoint "$summary_provider" && ! custom_hidden "$summary_provider" && model_served "$summary_provider" "$summary_model"; then
  pass "summarization '$summary_provider' / '$summary_model' resolves"
else
  fail "summarization '$summary_provider' / '$summary_model' does not resolve to an offered model — long chats would lose history instead of summarizing it"
fi

# The retired custom endpoint keeps titleConvo: true while it still serves
# unmigrated agents, for the same reason as above.
for name in "${CUSTOM_ENDPOINTS[@]}"; do
  tc="$(yq -r ".endpoints.custom[] | select(.name == \"$name\") | .titleConvo" librechat.yaml)"
  if [ "$tc" = "true" ]; then
    pass "custom endpoint '$name' has titleConvo: true"
  else
    fail "custom endpoint '$name' titleConvo is '${tc:-unset}', must be true while agents can still use it"
  fi
done

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
group "Generated letters are written, served, and not enumerable"
# =============================================================================
# LibreChat v0.8.7 discards `blob` from an MCP embedded resource, so LetterWriter
# writes the .docx to the data disk and returns a URL that Caddy serves. Four
# things have to line up, and every one of them fails silently: the letter is
# generated correctly either way, and the failure only surfaces when somebody
# clicks a link and gets a 404 — or, worse, gets a directory listing.

lw_out="$(yq -r '.services."letterwriter-mcp".environment.LETTER_OUTPUT_DIR // ""' compose.yaml)"
lw_url="$(yq -r '.services."letterwriter-mcp".environment.LETTER_PUBLIC_BASE_URL // ""' compose.yaml)"
if [ -n "$lw_out" ] && [ -n "$lw_url" ]; then
  pass "letterwriter-mcp has both LETTER_OUTPUT_DIR and LETTER_PUBLIC_BASE_URL"
else
  fail "letterwriter-mcp needs BOTH LETTER_OUTPUT_DIR and LETTER_PUBLIC_BASE_URL (got '${lw_out:-unset}' / '${lw_url:-unset}') — the server refuses to start with only one"
fi

# The URL path Caddy serves must match the one the MCP advertises. A mismatch
# produces letters that exist on disk and 404 in the browser.
url_path="${lw_url##*/}"
if grep -qE "handle_path[[:space:]]+/${url_path}/\*" Caddyfile; then
  pass "Caddyfile serves /${url_path}/* , matching LETTER_PUBLIC_BASE_URL"
else
  fail "LETTER_PUBLIC_BASE_URL ends in '/${url_path}' but the Caddyfile has no 'handle_path /${url_path}/*' — every letter URL would 404"
fi

# Directory listing would expose every token, and therefore every letter, to
# anyone who requests the directory. It is one word away at all times.
if grep -qE '^\s*file_server\s+.*browse' Caddyfile; then
  fail "Caddyfile enables file_server 'browse' — that lets anyone enumerate every generated letter"
else
  pass "Caddyfile does not enable directory browsing"
fi

# Caddy has no reason to write to a public document root.
if yaml_array_contains compose.yaml '.services.caddy.volumes' "\${DATA_DIR}/letters:/srv/letters:ro"; then
  pass "Caddy mounts the letters directory read-only"
else
  fail "Caddy's letters mount is missing or not :ro — a writable public document root"
fi


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
group "Infrastructure defaults and host retention match production"
# =============================================================================

bicep_vm_size="$(grep -oP "param vmSize string = '\K[^']+" infra/main.bicep)"
example_vm_size="$(jq -r '.parameters.vmSize.value' infra/main.parameters.example.json)"
bicep_os_disk="$(grep -oP 'param osDiskSizeGb int = \K[0-9]+' infra/main.bicep)"
example_os_disk="$(jq -r '.parameters.osDiskSizeGb.value' infra/main.parameters.example.json)"

[ "$bicep_vm_size" = "Standard_D2s_v5" ] \
  && pass "Bicep VM default is Standard_D2s_v5" \
  || fail "Bicep VM default is '$bicep_vm_size', expected Standard_D2s_v5"
[ "$example_vm_size" = "Standard_D2s_v5" ] \
  && pass "example VM size is Standard_D2s_v5" \
  || fail "example VM size is '$example_vm_size', expected Standard_D2s_v5"
[ "$bicep_os_disk" = "128" ] && [ "$example_os_disk" = "128" ] \
  && pass "Bicep and example OS disk defaults are 128 GB" \
  || fail "OS disk defaults differ from production: Bicep='$bicep_os_disk', example='$example_os_disk'"

if bash -n scripts/host-maintenance.sh scripts/install-host-maintenance.sh; then
  pass "host-maintenance scripts parse"
else
  fail "host-maintenance scripts do not parse"
fi

if bash -n scripts/backup-mongo.sh scripts/restore.sh; then
  pass "backup and restore scripts parse"
else
  fail "backup and restore scripts do not parse"
fi

# A restore that skips either of these "succeeds" with search or document chat
# silently broken. Both were missing until 2026-10; keep them from regressing.
if grep -Fq 'reset-meili-flags.js' scripts/restore.sh \
   && grep -Fq 'langchain_pg_embedding' scripts/restore.sh \
   && grep -Fq 'langchain_pg_embedding' scripts/backup-mongo.sh; then
  pass "backups include the vector database, and restores rebuild search"
else
  fail "restore.sh or backup-mongo.sh lost the vector database or search-index steps"
fi

if grep -Fq 'ExecStart=/srv/librechat/app/scripts/host-maintenance.sh --apply' \
     infra/systemd/librechat-host-maintenance.service \
   && grep -Fq 'OnCalendar=Sun *-*-* 04:17:00 UTC' \
     infra/systemd/librechat-host-maintenance.timer; then
  pass "weekly host-maintenance service applies the versioned cleanup policy"
else
  fail "host-maintenance systemd units are missing their command or weekly schedule"
fi

if grep -Fq 'scripts/install-host-maintenance.sh' scripts/deploy.sh \
   && grep -Fq 'scripts/install-host-maintenance.sh' infra/cloud-init.yaml; then
  pass "new and existing hosts install the host-maintenance timer"
else
  fail "host-maintenance timer is not installed by both cloud-init and deploy.sh"
fi


# =============================================================================
group "Code interpreter module (optional) is self-consistent"
# =============================================================================
# The interpreter stack runs on its own VM from codeinterpreter/. Its failures
# are quiet ones: a variable nobody sets starts a service with an empty value,
# and a health line whose fields drift from the alert queries parses as nulls,
# which silences the alerts instead of firing them.
CI_COMPOSE=codeinterpreter/compose.yaml
CI_DEFAULTS=codeinterpreter/env.defaults

unpinned="$(yq -r '.services[].image' "$CI_COMPOSE" | grep -v '@sha256:[0-9a-f]\{64\}$' || true)"
if [ -z "$unpinned" ]; then
  pass "every interpreter image is pinned by digest"
else
  fail "interpreter images not pinned by digest: $(echo "$unpinned" | tr '\n' ' ')"
fi

# Every ${VAR} in the compose file must come from env.defaults or from Key
# Vault, where scripts/codeinterpreter-seed-secrets.sh writes it.
ci_referenced="$(grep -o '\${[A-Z_][A-Z0-9_]*' "$CI_COMPOSE" | sed 's/^\${//' | sort -u)"
ci_defaults="$(grep -o '^[A-Z_][A-Z0-9_]*=' "$CI_DEFAULTS" | tr -d '=' | sort -u)"
ci_seeded="$(grep -oE '^(generate|put) [A-Z][A-Z0-9-]*|put [A-Z][A-Z0-9-]* ' scripts/codeinterpreter-seed-secrets.sh \
  | awk '{print $2}' | tr '-' '_' | sort -u)"
ci_seeded="$ci_seeded"$'\n'"CODEAPI_EXECUTION_MANIFEST_PRIVATE_KEY"$'\n'"SANDBOX_EXECUTION_MANIFEST_PUBLIC_KEY"
ci_missing=""
for var in $ci_referenced; do
  grep -qx "$var" <<<"$ci_defaults" || grep -qx "$var" <<<"$ci_seeded" || ci_missing="$ci_missing $var"
done
if [ -z "$ci_missing" ]; then
  pass "every interpreter variable comes from env.defaults or the seeded vault"
else
  fail "interpreter variables with no source:$ci_missing"
fi

if grep -Eq '^[A-Z_]*(PASSWORD|SECRET|TOKEN|PRIVATE)[A-Z_]*=' "$CI_DEFAULTS"; then
  fail "$CI_DEFAULTS names something that looks like a secret; secrets belong in Key Vault"
else
  pass "interpreter env.defaults holds no secret-shaped names"
fi

if grep -q 'CODEAPI_BRIDGE_' "$CI_COMPOSE"; then
  fail "$CI_COMPOSE sets CODEAPI_BRIDGE_*; the bridge is meant to stay at its disabled default"
elif grep -Fq '@bridge path /v1/bridge' codeinterpreter/caddy/Caddyfile \
     && grep -Fq '@metrics path /metrics' codeinterpreter/caddy/Caddyfile; then
  pass "the bridge stays disabled, and Caddy refuses /v1/bridge and /metrics"
else
  fail "codeinterpreter/caddy/Caddyfile no longer refuses /v1/bridge or /metrics"
fi

# The alert queries parse the health line positionally.
health_fields="$(grep -o '[a-z_]*=\${' scripts/codeinterpreter-health.sh | tr -d '=${' | tr '\n' ' ')"
alert_fields="$(grep -o '"[ ]*[a-z_]*=" [a-z_]*:int' infra/codeinterpreter/main.bicep | awk '{print $NF}' | sed 's/:int//' | tr '\n' ' ')"
if [ -n "$health_fields" ] && [ "$health_fields" = "$alert_fields" ]; then
  pass "the health snapshot line and the alert queries agree field for field"
else
  fail "health line fields [$health_fields] differ from the alert parse [$alert_fields]"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ci_env="$(mktemp)"
  { cat "$CI_DEFAULTS"; for var in $ci_seeded; do echo "$var=placeholder"; done; } > "$ci_env"
  if docker compose -f "$CI_COMPOSE" --env-file "$ci_env" config --quiet 2>/tmp/ci-compose.err; then
    pass "interpreter compose renders with defaults plus seeded names"
  else
    fail "interpreter compose does not render: $(head -3 /tmp/ci-compose.err)"
  fi
  rm -f "$ci_env"
else
  echo "  – compose render skipped (docker not installed)"
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
