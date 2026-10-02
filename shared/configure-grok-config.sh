#!/bin/bash
# Managed Grok configuration for the b2b grok image (the images without Grok carry neither
# the CLI nor this script, and their entrypoints skip the step). The entrypoint runs it at
# every boot, since the managed token rotates on recreate. Grok reads ~/.grok/config.toml
# (GROK_HOME on the persisted volume); this script owns exactly the [mcp_servers.composio]
# table (with its subtables) in that file and regenerates only that. Everything else is the
# customer's and is carried over untouched.
#
# Ownership is decided by TOML structure, never by comment markers: `grok mcp add` rewrites
# the whole file through a TOML serializer that drops every comment, so markers vanish the
# first time a customer adds their own server. A marker-delimited block then goes unfound at
# the next boot, gets kept as "customer content", and a second [mcp_servers.composio] lands
# below it: a duplicate key, which makes grok reject the whole file and lose every MCP server.
#
# The customer's model credential is never touched here: it is their own XAI_API_KEY in the
# instance environment (grok reads the env var directly) or a `grok login` done in the
# terminal.
set -euo pipefail

GROK_BIN="${GROK_BIN:-/usr/local/bin/grok}"
GROK_HOME="${GROK_HOME:-${HOME}/.grok}"
CONFIG_PATH="${GROK_HOME}/config.toml"
RULES_PATH="${GROK_HOME}/rules/agent37-composio.md"
COMPOSIO_MCP_URL="${AGENT37_COMPOSIO_MCP_URL:-}"

log() {
  printf '%s [agent37-grok-config] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -x "${GROK_BIN}" ]; then
  log "No Grok binary at ${GROK_BIN}; skipping."
  exit 0
fi

mkdir -p "${GROK_HOME}"

# The customer's config.toml, split into the root section (keys before the first table
# header, which TOML requires to come first) and the tables, minus what we own: every
# [mcp_servers.composio*] table and our own comment lines (every comment this script writes
# starts with "# agent37", which also covers the block markers older releases wrote;
# "# Managed by Agent37" is the other legacy marker line).
customer_config() {
  [ -f "${CONFIG_PATH}" ] || return 0
  awk -v mode="$1" '
    BEGIN {
      # Our table headers: [mcp_servers.composio] and [mcp_servers.composio.<sub>], each key
      # bare, double-quoted, or single-quoted (a literal key). A quoted key such as
      # "composio.x" is one key, so a different server: kept.
      q = sprintf("%c", 39)
      ours = "^[[:space:]]*\\[[[:space:]]*(\"mcp_servers\"|" q "mcp_servers" q "|mcp_servers)[[:space:]]*\\.[[:space:]]*(\"composio\"|" q "composio" q "|composio)[[:space:]]*(\\]|\\.)"
    }
    /^# agent37-managed:grok:start$/ { legacy = 1; next }
    /^# agent37-managed:grok:end$/ { legacy = 0; next }
    legacy && /^[[:space:]]*#/ { next }
    /^# agent37/ || /^# Managed by Agent37/ { next }
    /^[[:space:]]*\[[^]]*\][[:space:]]*(#.*)?$/ {
      in_tables = 1
      skip = ($0 ~ ours)
    }
    in_tables { if (mode == "tables" && !skip) print; next }
    { if (mode == "root") print }
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
  composio_toml=$'[mcp_servers.composio]\nurl = "'"${COMPOSIO_MCP_URL}"$'"\n\n[mcp_servers.composio.headers]\nAuthorization = "Bearer '"${STARTER_TOKEN}"$'"'
  log "Composio MCP server registered for Grok."
else
  log "Composio MCP server not registered for Grok (enabled=${HERMES_COMPOSIO_ENABLED:-unset} token_set=$([ -n "${STARTER_TOKEN:-}" ] && echo yes || echo no) url_set=$([ -n "${COMPOSIO_MCP_URL}" ] && echo yes || echo no))."
fi

# Layout: the customer's root keys, our composio table, the customer's tables. Ours sits
# after every root key (a table would swallow any root key below it) and before the
# customer's tables, so the tail of the file stays theirs.
{
  [ -n "${customer_root}" ] && printf '%s\n\n' "${customer_root}"
  if [ -n "${composio_toml}" ]; then
    printf '# agent37: managed at every boot. The [mcp_servers.composio] table is regenerated;\n'
    printf '# agent37: everything else in this file is yours and survives boots.\n'
    printf '%s\n' "${composio_toml}"
    [ -n "${customer_tables}" ] && printf '\n'
  fi
  [ -n "${customer_tables}" ] && printf '%s\n' "${customer_tables}"
} > "${CONFIG_PATH}"

# Managed guidance as a home-level rules file (grok loads every *.md in ~/.grok/rules/ into
# context): registering the server alone does not teach the agent to reach for it when someone
# says "connect my Gmail". The file is wholly managed, rewritten when a section applies and
# removed when none do, and each section carries its own gate: schedules work with or without
# Composio, so that paragraph rides the `agent37` CLI alone, as the Hermes plugin gates it.
HAS_CRON=false
if command -v agent37 >/dev/null 2>&1; then
  HAS_CRON=true
fi

if [ -n "${composio_toml}" ] || "${HAS_CRON}"; then
  mkdir -p "$(dirname "${RULES_PATH}")"
  : > "${RULES_PATH}"
fi

if [ -n "${composio_toml}" ]; then
  cat >> "${RULES_PATH}" <<'RULES'
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

RULES
fi

if "${HAS_CRON}"; then
  cat >> "${RULES_PATH}" <<'RULES'
## Recurring work

Agent37 runs schedules outside this container, so a firing wakes the machine to deliver its
prompt and it is free to sleep in between; a crontab (or systemd timer, or sleep loop) in here
stops the moment the machine sleeps. Use `agent37 cron add --schedule "0 9 * * 1-5" --prompt
"..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt
arrives as a fresh message in its own chat, so write it to stand on its own. Docs:
https://www.agent37.com/docs/agents-api/crons

RULES
fi

if [ -n "${composio_toml}" ] || "${HAS_CRON}"; then
  cat >> "${RULES_PATH}" <<'RULES'
(This file is managed by Agent37 and rewritten at every boot; edits are lost.)
RULES
  log "Managed guidance written to Grok rules (composio=$([ -n "${composio_toml}" ] && echo true || echo false) cron=${HAS_CRON})."
else
  rm -f "${RULES_PATH}"
fi
