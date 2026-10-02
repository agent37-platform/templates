#!/bin/bash
# Managed Codex configuration for the images that bake Codex (the consumer app image and the
# b2b codex image; the b2b hermes/openclaw images carry neither the CLI nor this script, and
# their entrypoint skips the step). The entrypoint runs it at every boot, since the managed
# token rotates on recreate. Codex reads ~/.codex/config.toml (CODEX_HOME on the persisted
# volume); this script owns exactly two things in that file and regenerates only those:
# the root keys seeded from codex-system-config.toml, and the [mcp_servers.composio] table
# (with any subtables). Everything else is the customer's and is carried over untouched.
#
# Ownership is decided by TOML structure, never by comment markers. `codex mcp add` rewrites
# the file through a TOML editor that drops nothing but places the new [mcp_servers.<name>]
# table right after the existing ones and reformats ours (inline table -> subtable), so a
# marker-delimited block would either swallow the customer's server (deleted at the next
# boot) or drift away from what it was meant to own.
#
# The customer's model credential is never touched here: it is their own ChatGPT login
# (codex login --device-auth) or OPENAI_API_KEY, materialized into ~/.codex/auth.json by the
# entrypoint's ensure_codex_login, not by this script.
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-/usr/local/bin/codex}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_HOME}/config.toml"
AGENTS_PATH="${CODEX_HOME}/AGENTS.md"
BASE_CONFIG="${CODEX_BASE_CONFIG:-/usr/local/lib/agent37/codex-system-config.toml}"
COMPOSIO_MCP_URL="${AGENT37_COMPOSIO_MCP_URL:-}"

MEMORY_START='<!-- agent37-managed:composio:start -->'
MEMORY_END='<!-- agent37-managed:composio:end -->'

log() {
  printf '%s [agent37-codex-config] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -x "${CODEX_BIN}" ]; then
  log "No Codex binary at ${CODEX_BIN}; skipping."
  exit 0
fi

mkdir -p "${CODEX_HOME}"

BASE_TOML=""
if [ -f "${BASE_CONFIG}" ]; then
  BASE_TOML="$(cat "${BASE_CONFIG}")"
else
  # Fallback so a headless terminal still never blocks on approvals if the seed is missing.
  BASE_TOML=$'approval_policy = "never"\nsandbox_mode = "danger-full-access"'
fi
# Only the seed's key lines go into config.toml (its comments are for readers of this repo);
# the root keys this script owns are exactly those, plus experimental_use_rmcp_client, which
# older images seeded and Codex >= 0.156 warns about at startup, so it is still stripped.
BASE_KEYS="$(printf '%s\n' "${BASE_TOML}" | sed -n '/^[[:space:]]*[A-Za-z0-9_-][A-Za-z0-9_-]*[[:space:]]*=/p')"
MANAGED_ROOT_KEYS="$(printf '%s\n' "${BASE_KEYS}" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_-]*\)[[:space:]]*=.*/\1/p' | tr '\n' ' ') experimental_use_rmcp_client"

# The customer's half of config.toml, split into the root section (keys before the first
# table header, which TOML requires to come first) and the tables, minus what we own:
# managed root keys, every [mcp_servers.composio*] table, and our own comment lines (every
# comment this script writes starts with "# agent37", which also covers the block markers
# older releases wrote; "# Managed by Agent37" is the other legacy marker line).
customer_config() {
  [ -f "${CONFIG_PATH}" ] || return 0
  awk -v mode="$1" -v keys="${MANAGED_ROOT_KEYS}" '
    BEGIN {
      n = split(keys, list, " "); for (i = 1; i <= n; i++) if (list[i] != "") owned[list[i]] = 1
      # Our table headers: [mcp_servers.composio] and [mcp_servers.composio.<sub>], each key
      # bare, double-quoted, or single-quoted (a literal key). A quoted key such as
      # "composio.x" is one key, so a different server: kept.
      q = sprintf("%c", 39)
      ours = "^[[:space:]]*\\[[[:space:]]*(\"mcp_servers\"|" q "mcp_servers" q "|mcp_servers)[[:space:]]*\\.[[:space:]]*(\"composio\"|" q "composio" q "|composio)[[:space:]]*(\\]|\\.)"
    }
    /^# agent37-managed:codex:start$/ { legacy = 1; next }
    /^# agent37-managed:codex:end$/ { legacy = 0; next }
    legacy && /^[[:space:]]*#/ { next }
    /^# agent37/ || /^# Managed by Agent37/ { next }
    /^[[:space:]]*\[[^]]*\][[:space:]]*(#.*)?$/ {
      in_tables = 1
      skip = ($0 ~ ours)
      if (mode == "tables" && !skip) print
      next
    }
    in_tables { if (mode == "tables" && !skip) print; next }
    {
      key = $0; sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*=.*$/, "", key)
      if (mode == "root" && !(key in owned)) print
    }
  ' "${CONFIG_PATH}"
}

# Squeeze blank runs and trim blank edges so separators never accumulate across boots.
tidy_blank_lines() {
  awk 'NF { started = 1 } started { buf = buf $0 "\n" } END { gsub(/\n\n+/, "\n\n", buf); sub(/\n+$/, "", buf); printf "%s", buf }'
}

customer_root="$(customer_config root | tidy_blank_lines)"
customer_tables="$(customer_config tables | tidy_blank_lines)"

composio_toml=""
if is_truthy "${HERMES_COMPOSIO_ENABLED:-}" && [ -n "${STARTER_TOKEN:-}" ] && [ -n "${COMPOSIO_MCP_URL}" ]; then
  composio_toml=$'[mcp_servers.composio]\nurl = "'"${COMPOSIO_MCP_URL}"$'"\nhttp_headers = { "Authorization" = "Bearer '"${STARTER_TOKEN}"$'" }'
  log "Composio MCP server registered for Codex."
else
  log "Composio MCP server not registered for Codex (enabled=${HERMES_COMPOSIO_ENABLED:-unset} token_set=$([ -n "${STARTER_TOKEN:-}" ] && echo yes || echo no) url_set=$([ -n "${COMPOSIO_MCP_URL}" ] && echo yes || echo no))."
fi

# Layout: managed root keys, the customer's root keys, our composio table, the customer's
# tables. Ours sits after every root key (a table would swallow any root key below it) and
# before the customer's tables, so the tail of the file stays theirs.
{
  printf '# agent37: managed at every boot. The root keys below and the [mcp_servers.composio] table\n'
  printf '# agent37: are regenerated; everything else in this file is yours and survives boots.\n'
  printf '%s\n' "${BASE_KEYS}"
  [ -n "${customer_root}" ] && printf '\n%s\n' "${customer_root}"
  if [ -n "${composio_toml}" ]; then
    printf '\n# agent37: managed at every boot; regenerated, edits are lost.\n'
    printf '%s\n' "${composio_toml}"
  fi
  [ -n "${customer_tables}" ] && printf '\n%s\n' "${customer_tables}"
} > "${CONFIG_PATH}"

# Composio usage guidance in Codex's project memory (~/.codex/AGENTS.md, which the gateway's
# turns load): registering the server alone does not teach the agent to reach for it when
# someone says "connect my Gmail". Marker-delimited so boots rewrite only their own section,
# and each section inside it carries its own gate: schedules work with or without Composio,
# so that paragraph rides the `agent37` CLI alone, exactly as the Hermes plugin gates it.
strip_composio_memory() {
  [ -f "${AGENTS_PATH}" ] || return 0
  tmp="$(mktemp)"
  awk -v s="${MEMORY_START}" -v e="${MEMORY_END}" '$0==s{skip=1} !skip{print} $0==e{skip=0}' \
    "${AGENTS_PATH}" > "${tmp}"
  cat "${tmp}" > "${AGENTS_PATH}"
  rm -f "${tmp}"
}

ensure_trailing_newline() {
  [ -s "${AGENTS_PATH}" ] || return 0
  if [ "$(tail -c 1 "${AGENTS_PATH}")" != "" ]; then
    printf '\n' >> "${AGENTS_PATH}"
  fi
}

HAS_CRON=false
if command -v agent37 >/dev/null 2>&1; then
  HAS_CRON=true
fi

strip_composio_memory
if [ -n "${composio_toml}" ] || "${HAS_CRON}"; then
  ensure_trailing_newline
  printf '%s\n' "${MEMORY_START}" >> "${AGENTS_PATH}"
fi

if [ -n "${composio_toml}" ]; then
  cat >> "${AGENTS_PATH}" <<'MEMORY'
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

MEMORY
fi

if "${HAS_CRON}"; then
  cat >> "${AGENTS_PATH}" <<'MEMORY'
## Recurring work

Agent37 runs schedules outside this container, so a firing wakes the machine to deliver its
prompt and it is free to sleep in between; a crontab (or systemd timer, or sleep loop) in here
stops the moment the machine sleeps. Use `agent37 cron add --schedule "0 9 * * 1-5" --prompt
"..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt
arrives as a fresh message in its own chat, so write it to stand on its own. Docs:
https://www.agent37.com/docs/agents-api/crons

MEMORY
fi

if [ -n "${composio_toml}" ] || "${HAS_CRON}"; then
  cat >> "${AGENTS_PATH}" <<'MEMORY'
(This section is managed by Agent37 and rewritten at every boot; edits inside it are lost.)
MEMORY
  printf '%s\n' "${MEMORY_END}" >> "${AGENTS_PATH}"
  log "Managed guidance written to Codex memory (composio=$([ -n "${composio_toml}" ] && echo true || echo false) cron=${HAS_CRON})."
fi
