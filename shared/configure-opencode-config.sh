#!/bin/bash
# Managed OpenCode configuration for the images that bake OpenCode (the b2b opencode image; the
# b2b hermes/openclaw/codex/claude-code images carry neither the CLI nor this script, and their
# entrypoint skips the step). The entrypoint runs it at every boot, since the managed token
# rotates on recreate. OpenCode reads ~/.config/opencode/opencode.json (merged under the
# gateway's inline OPENCODE_CONFIG_CONTENT posture), so this owns three managed keys in that
# file and deep-merges them with jq, preserving any other keys the customer set:
#   provider.agent37  the managed Agent37 model (custom openai-compatible provider)
#   model             the default model, bootstrapped/refreshed to agent37/<id> (never
#                     overwriting a customer's own BYO model choice)
#   mcp.composio      the managed Composio MCP server
# plus one entry in `instructions` pointing at a managed guidance file this script writes.
#
# The customer's own provider key (OPENAI_API_KEY and friends) is never touched here: OpenCode
# reads it natively from the container env. This script only wires the managed model + Composio.
set -euo pipefail

OPENCODE_BIN="${OPENCODE_BIN:-/usr/local/bin/opencode}"
CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_PATH="${CONFIG_DIR}/opencode.json"
INSTRUCTIONS_PATH="${CONFIG_DIR}/agent37-composio.md"

STARTER_TOKEN="${STARTER_TOKEN:-}"
LLM_PROXY_URL="${LLM_PROXY_URL:-}"
MANAGED_MODEL_ID="${MANAGED_MODEL_ID:-default}"
COMPOSIO_MCP_URL="${COMPOSIO_MCP_URL:-}"

log() {
  printf '%s [agent37-opencode-config] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -x "${OPENCODE_BIN}" ]; then
  log "No OpenCode binary at ${OPENCODE_BIN}; skipping."
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found; skipping OpenCode config update."
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

HAS_COMPOSIO=false
if is_truthy "${HERMES_COMPOSIO_ENABLED:-}" && [ -n "${STARTER_TOKEN}" ] && [ -n "${COMPOSIO_MCP_URL}" ]; then
  HAS_COMPOSIO=true
fi

# Schedules work with or without Composio, so the cron section of the managed instructions file
# rides the `agent37` CLI alone (exactly as the Hermes plugin gates it), and the file is loaded
# whenever either section applies. Its name stays agent37-composio.md: the path is what the
# `instructions` key below adds and removes, so renaming it would orphan the old entry.
HAS_CRON=false
if command -v agent37 >/dev/null 2>&1; then
  HAS_CRON=true
fi
HAS_GUIDANCE=false
if "${HAS_COMPOSIO}" || "${HAS_CRON}"; then
  HAS_GUIDANCE=true
fi

# Start from the existing config (a customer's own edits) or {}. A file the customer broke is
# not ours to preserve — if it does not parse, start clean so the managed model still comes up.
base='{}'
if [ -s "${CONFIG_PATH}" ] && jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
  base="$(cat "${CONFIG_PATH}")"
fi

# The managed provider advertises every model the platform serves, fetched live from the proxy's
# OpenAI-compatible model list (GET <base>/models). A newly released managed model then shows up
# in the picker on the instance's next boot with no image rebuild. OpenCode's custom-provider
# config has no model auto-discovery, so we materialize the list here. A failed or empty fetch
# falls back to the single default alias so the managed model always comes up.
MANAGED_MODELS="$(jq -cn --arg id "${MANAGED_MODEL_ID}" '{ ($id): { name: "Agent37 Managed" } }')"
if "${HAS_MANAGED}"; then
  models_json="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${STARTER_TOKEN}" "${BASE_URL}/models" 2>/dev/null || true)"
  if [ -n "${models_json}" ]; then
    fetched="$(printf '%s' "${models_json}" | jq -c '
      (.data // [])
      | map(select((.id | type) == "string" and (.id | length) > 0))
      | map({ key: .id, value: { name: ((.name // .id) | tostring) } })
      | from_entries
    ' 2>/dev/null || true)"
    if [ -n "${fetched}" ] && [ "${fetched}" != "{}" ]; then
      # Guarantee the default alias survives so the default model ref always resolves.
      MANAGED_MODELS="$(printf '%s' "${fetched}" | jq -c --arg id "${MANAGED_MODEL_ID}" \
        'if has($id) then . else . + { ($id): { name: "Agent37 Managed" } } end')"
      log "Managed model list: $(printf '%s' "${MANAGED_MODELS}" | jq 'length') models from the proxy."
    else
      log "Managed model list fetch returned no usable models; using the default alias only."
    fi
  else
    log "Managed model list fetch failed; using the default alias only."
  fi
fi

updated="$(
  printf '%s' "${base}" | jq \
    --arg base_url "${BASE_URL}" \
    --arg api_key "${STARTER_TOKEN}" \
    --arg model_id "${MANAGED_MODEL_ID}" \
    --arg model_ref "agent37/${MANAGED_MODEL_ID}" \
    --arg composio_url "${COMPOSIO_MCP_URL}" \
    --arg composio_auth "Bearer ${STARTER_TOKEN}" \
    --arg instr "${INSTRUCTIONS_PATH}" \
    --argjson managed_models "${MANAGED_MODELS}" \
    --argjson has_managed "${HAS_MANAGED}" \
    --argjson has_composio "${HAS_COMPOSIO}" \
    --argjson has_guidance "${HAS_GUIDANCE}" '
    ."$schema" = "https://opencode.ai/config.json"
    | if $has_managed then
        .provider.agent37 = {
          npm: "@ai-sdk/openai-compatible",
          name: "Agent37 (managed)",
          options: { baseURL: $base_url, apiKey: $api_key },
          models: $managed_models
        }
        | (if ((.model // "") | (. == "" or startswith("agent37/"))) then .model = $model_ref else . end)
      else
        (if .provider then del(.provider.agent37) else . end)
        | (if ((.model // "") | startswith("agent37/")) then del(.model) else . end)
      end
    | if $has_composio then
        .mcp.composio = { type: "remote", url: $composio_url, enabled: true, headers: { Authorization: $composio_auth } }
      else
        (if .mcp then del(.mcp.composio) else . end)
      end
    | if $has_guidance then
        .instructions = (((.instructions // []) - [$instr]) + [$instr])
      else
        .instructions = ((.instructions // []) - [$instr])
      end
    | (if (.instructions == []) then del(.instructions) else . end)
    | (if (.mcp == {}) then del(.mcp) else . end)
    | (if (.provider == {}) then del(.provider) else . end)
  '
)"

if [ -z "${updated}" ]; then
  log "Warning: failed to build OpenCode config; leaving ${CONFIG_PATH} unchanged."
  exit 0
fi
printf '%s\n' "${updated}" > "${CONFIG_PATH}"

if "${HAS_MANAGED}"; then
  log "Managed Agent37 model configured for OpenCode (default ${MANAGED_MODEL_ID})."
else
  log "Managed Agent37 model not configured (base_url_set=$([ -n "${BASE_URL}" ] && echo yes || echo no) token_set=$([ -n "${STARTER_TOKEN}" ] && echo yes || echo no)); OpenCode runs on the customer's own provider keys."
fi

# The managed instructions file OpenCode loads for every turn (via the `instructions` config key
# above): registering the Composio server alone does not teach the agent to reach for it when
# someone says "connect my Gmail". Rewritten wholesale each boot, section by section, and
# removed when no section applies.
if "${HAS_GUIDANCE}"; then
  : > "${INSTRUCTIONS_PATH}"
fi

if "${HAS_COMPOSIO}"; then
  cat >> "${INSTRUCTIONS_PATH}" <<'GUIDE'
## Connected apps (Composio)

This machine has a `composio` MCP server: Agent37's managed OAuth path to third-party SaaS
apps (Gmail, Google Calendar, Notion, GitHub, Linear, Jira, HubSpot, Salesforce, Airtable,
and similar). Its tools are self-describing; discover them from that server rather than
assuming tool names.

- Use it whenever the user wants to connect to or act on a general SaaS app. To connect one,
  start the Composio connection flow, show the returned OAuth link as a markdown link, and
  wait for the user to confirm before checking connection status.
- Try Composio before telling the user to get an API key or configure a vendor dashboard for
  a general SaaS app. Connections persist on this machine; reuse them.

## Building another agent

Agent37, the platform this machine runs on, has a public API for creating agents: docs at
https://www.agent37.com/docs, API keys at https://www.agent37.com/dashboard/cloud/api-keys.
If the user wants another agent, that is the way to build it, and you can do it for them.

GUIDE
  log "Composio MCP server registered for OpenCode."
else
  log "Composio MCP server not registered for OpenCode."
fi

if "${HAS_CRON}"; then
  cat >> "${INSTRUCTIONS_PATH}" <<'GUIDE'
## Recurring work

Agent37 runs schedules outside this container, so a firing wakes the machine to deliver its
prompt and it is free to sleep in between; a crontab (or systemd timer, or sleep loop) in here
stops the moment the machine sleeps. Use `agent37 cron add --schedule "0 9 * * 1-5" --prompt
"..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt
arrives as a fresh message in its own chat, so write it to stand on its own. Docs:
https://www.agent37.com/docs/agents-api/crons

GUIDE
fi

if "${HAS_GUIDANCE}"; then
  cat >> "${INSTRUCTIONS_PATH}" <<'GUIDE'
(This section is managed by Agent37 and rewritten at every boot; edits inside it are lost.)
GUIDE
  log "Managed guidance written for OpenCode (composio=${HAS_COMPOSIO} cron=${HAS_CRON})."
else
  rm -f "${INSTRUCTIONS_PATH}"
fi
