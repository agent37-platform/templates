#!/bin/bash
# Managed Pi configuration for the images that bake Pi (the b2b pi image; the other b2b images
# carry neither the CLI nor this script, and their entrypoints skip the step). The entrypoint
# runs it at every boot, since the managed model list can change. Pi reads its own config from
# the agent directory, and this owns three things there, merging with whatever the customer set:
#   models.json    providers.agent37 — the managed Agent37 model (openai-compatible endpoint)
#   settings.json  defaultProvider/defaultModel, bootstrapped once to the managed model (never
#                  overwriting a choice the customer made, managed model or their own provider)
#   APPEND_SYSTEM.md  managed guidance appended to pi's system prompt
#
# The managed token is NOT written to disk: models.json takes `$AGENT37_MANAGED_TOKEN` and pi
# interpolates it from the environment at request time, so a rotated token needs no rewrite.
#
# The customer's own provider key (ANTHROPIC_API_KEY and friends) is never touched here: pi
# reads it natively from the container env, as it does a `/login` credential from its auth.json.
#
# No Composio: pi has no MCP client yet (upstream PR earendil-works/pi#10040). Register the
# managed server here once that lands, the way the other harness images do.
set -euo pipefail

PI_BIN="${PI_BIN:-/usr/local/bin/pi}"
CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
MODELS_PATH="${CONFIG_DIR}/models.json"
SETTINGS_PATH="${CONFIG_DIR}/settings.json"
GUIDANCE_PATH="${CONFIG_DIR}/APPEND_SYSTEM.md"

STARTER_TOKEN="${STARTER_TOKEN:-}"
LLM_PROXY_URL="${LLM_PROXY_URL:-}"
MANAGED_MODEL_ID="${MANAGED_MODEL_ID:-default}"

log() {
  printf '%s [agent37-pi-config] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

if [ ! -x "${PI_BIN}" ]; then
  log "No Pi binary at ${PI_BIN}; skipping."
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found; skipping Pi config update."
  exit 0
fi

mkdir -p "${CONFIG_DIR}"

# The managed proxy expects a base URL ending in /v1 (the control plane injects /llm/v1, so
# this is usually a no-op; guard the deprecated alias forms).
normalize_base_url() {
  local url="${1%/}"
  case "${url}" in
    "") printf '' ;;
    */v1) printf '%s' "${url}" ;;
    *) printf '%s/v1' "${url}" ;;
  esac
}
BASE_URL="$(normalize_base_url "${LLM_PROXY_URL}")"

HAS_MANAGED=false
[ -n "${BASE_URL}" ] && [ -n "${STARTER_TOKEN}" ] && HAS_MANAGED=true

# Merge into the existing file (a customer's own edits) or {}. A file the customer broke is not
# ours to preserve — if it does not parse, start clean so the managed model still comes up.
read_json() {
  if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then
    cat "$1"
  else
    printf '{}'
  fi
}

# The managed provider advertises every model the platform serves, fetched live from the proxy's
# OpenAI-compatible model list (GET <base>/models), so a newly released managed model shows up
# in pi's picker on the instance's next boot with no image rebuild. A failed or empty fetch
# falls back to the single default alias so the managed model always comes up.
MANAGED_MODELS="$(jq -cn --arg id "${MANAGED_MODEL_ID}" '[{ id: $id, name: "Agent37 Managed" }]')"
if "${HAS_MANAGED}"; then
  models_json="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${STARTER_TOKEN}" "${BASE_URL}/models" 2>/dev/null || true)"
  if [ -n "${models_json}" ]; then
    fetched="$(printf '%s' "${models_json}" | jq -c '
      (.data // [])
      | map(select((.id | type) == "string" and (.id | length) > 0))
      | map({ id: .id, name: ((.name // .id) | tostring) })
    ' 2>/dev/null || true)"
    if [ -n "${fetched}" ] && [ "${fetched}" != "[]" ]; then
      # Guarantee the default alias survives so the default model ref always resolves.
      MANAGED_MODELS="$(printf '%s' "${fetched}" | jq -c --arg id "${MANAGED_MODEL_ID}" \
        'if any(.id == $id) then . else . + [{ id: $id, name: "Agent37 Managed" }] end')"
      log "Managed model list: $(printf '%s' "${MANAGED_MODELS}" | jq 'length') models from the proxy."
    else
      log "Managed model list fetch returned no usable models; using the default alias only."
    fi
  else
    log "Managed model list fetch failed; using the default alias only."
  fi
fi

# models.json: own providers.agent37, leave every other provider and every modelOverride alone.
# apiKey is the literal "$AGENT37_MANAGED_TOKEN": pi reads environment interpolation at request
# time, so the rotating token never lands in the file.
models_updated="$(
  read_json "${MODELS_PATH}" | jq \
    --arg base_url "${BASE_URL}" \
    --argjson managed_models "${MANAGED_MODELS}" \
    --argjson has_managed "${HAS_MANAGED}" '
    if $has_managed then
      .providers.agent37 = {
        api: "openai-completions",
        baseUrl: $base_url,
        apiKey: "$AGENT37_MANAGED_TOKEN",
        models: $managed_models
      }
    else
      (if .providers then del(.providers.agent37) else . end)
    end
    | (if (.providers == {}) then del(.providers) else . end)
  '
)"
if [ -z "${models_updated}" ]; then
  log "Warning: failed to build Pi models.json; leaving ${MODELS_PATH} unchanged."
else
  printf '%s\n' "${models_updated}" > "${MODELS_PATH}"
fi

# settings.json: point pi's startup model at the managed one, unless the customer has chosen
# otherwise. Pi otherwise starts on whichever provider it finds authenticated. This is a
# bootstrap, not a reset: a customer who picked their own provider keeps it, and one who picked
# a different *managed* model (still provider agent37) keeps that model too.
settings_updated="$(
  read_json "${SETTINGS_PATH}" | jq \
    --arg provider agent37 \
    --arg model "${MANAGED_MODEL_ID}" \
    --argjson has_managed "${HAS_MANAGED}" '
    if $has_managed then
      (if ((.defaultProvider // "") == "") then .defaultProvider = $provider else . end)
      | (if (.defaultProvider == $provider and ((.defaultModel // "") == "")) then .defaultModel = $model else . end)
    else
      (if (.defaultProvider // "") == $provider then del(.defaultProvider) | del(.defaultModel) else . end)
    end
  '
)"
if [ -z "${settings_updated}" ]; then
  log "Warning: failed to build Pi settings.json; leaving ${SETTINGS_PATH} unchanged."
else
  printf '%s\n' "${settings_updated}" > "${SETTINGS_PATH}"
fi

if "${HAS_MANAGED}"; then
  log "Managed Agent37 model configured for Pi (default ${MANAGED_MODEL_ID})."
else
  log "Managed Agent37 model not configured (base_url_set=$([ -n "${BASE_URL}" ] && echo yes || echo no) token_set=$([ -n "${STARTER_TOKEN}" ] && echo yes || echo no)); Pi runs on the customer's own provider keys or /login."
fi

# Managed guidance, appended to pi's system prompt for every turn (pi reads APPEND_SYSTEM.md
# from its agent directory). Rewritten wholesale each boot, section by section: schedules ride
# the `agent37` CLI, which the managed stage bakes and the clean base does not.
cat > "${GUIDANCE_PATH}" <<'GUIDE'
## Building another agent

Agent37, the platform this machine runs on, has a public API for creating agents: docs at
https://www.agent37.com/docs, API keys at https://www.agent37.com/dashboard/cloud/api-keys.
If the user wants another agent, that is the way to build it, and you can do it for them.

GUIDE

if command -v agent37 >/dev/null 2>&1; then
  cat >> "${GUIDANCE_PATH}" <<'GUIDE'
## Recurring work

Agent37 runs schedules outside this container, so a firing wakes the machine to deliver its
prompt and it is free to sleep in between; a crontab (or systemd timer, or sleep loop) in here
stops the moment the machine sleeps. Use `agent37 cron add --schedule "0 9 * * 1-5" --prompt
"..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt
arrives as a fresh message in its own chat, so write it to stand on its own. Docs:
https://www.agent37.com/docs/agents-api/crons

GUIDE
fi

cat >> "${GUIDANCE_PATH}" <<'GUIDE'
(This file is managed by Agent37 and rewritten at every boot; edits are lost.)
GUIDE
