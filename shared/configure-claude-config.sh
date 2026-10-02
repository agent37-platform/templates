#!/bin/bash
# Managed Claude Code configuration for the images that bake Claude Code (the consumer app
# image and the b2b claude-code image; the b2b hermes images carry neither the CLI nor this
# script, and their entrypoint skips the step). The entrypoint runs it at every boot, since
# the managed token rotates on recreate. Everything goes through Claude Code's own writers
# so its files stay in the shape the CLI expects.
set -euo pipefail

CLAUDE_BIN="${CLAUDE_CODE_BIN:-/usr/local/bin/claude}"
SETTINGS_PATH="${HOME}/.claude/settings.json"
COMPOSIO_MCP_URL="${AGENT37_COMPOSIO_MCP_URL:-}"

log() {
  printf '%s [agent37-claude-config] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -x "${CLAUDE_BIN}" ]; then
  log "No Claude Code binary at ${CLAUDE_BIN}; skipping."
  exit 0
fi

# Transcript retention in the user settings as well as the baked
# /etc/claude-code/managed-settings.json: the gateway's session list is those transcripts,
# and Claude Code's default is a 30-day sweep.
mkdir -p "$(dirname "${SETTINGS_PATH}")"
if [ -s "${SETTINGS_PATH}" ]; then
  tmp="$(mktemp)"
  if jq '.cleanupPeriodDays = 3650' "${SETTINGS_PATH}" > "${tmp}" 2>/dev/null; then
    mv "${tmp}" "${SETTINGS_PATH}"
  else
    # A settings file the user broke is theirs to fix; the MCP step below must still run.
    rm -f "${tmp}"
    log "${SETTINGS_PATH} is not valid JSON; leaving it alone."
  fi
else
  printf '{\n  "cleanupPeriodDays": 3650\n}\n' > "${SETTINGS_PATH}"
fi

# The platform's Composio MCP server, registered user-scope under the same gate as the Hermes
# config updater (integration enabled, a managed token, the control plane's URL). Re-added on
# every boot so a rotated token replaces the old header; dropped when the gate is off. The
# matching guidance goes into Claude Code's user memory (~/.claude/CLAUDE.md, which the
# gateway's turns load): registering the server alone does not teach the agent to reach for
# it when someone says "connect my Gmail". Hermes gets the same text from its environment
# plugin; the managed block is marker-delimited so boots rewrite only their own section, and
# each section inside it carries its own gate: schedules work with or without Composio, so
# that paragraph rides the `agent37` CLI alone, exactly as the Hermes plugin gates it.
MEMORY_PATH="${HOME}/.claude/CLAUDE.md"
MARKER_START='<!-- agent37-managed:composio:start -->'
MARKER_END='<!-- agent37-managed:composio:end -->'

strip_composio_memory() {
  [ -f "${MEMORY_PATH}" ] || return 0
  tmp="$(mktemp)"
  awk -v s="${MARKER_START}" -v e="${MARKER_END}" '$0==s{skip=1} !skip{print} $0==e{skip=0}' \
    "${MEMORY_PATH}" > "${tmp}"
  # Rewrite in place (not mv): a customer may manage the file through a symlink.
  cat "${tmp}" > "${MEMORY_PATH}"
  rm -f "${tmp}"
}

# The block is appended and stripped by exact marker lines, so the file must end
# with a newline before the append or the start marker fuses onto the last line.
ensure_trailing_newline() {
  [ -s "${MEMORY_PATH}" ] || return 0
  if [ "$(tail -c 1 "${MEMORY_PATH}")" != "" ]; then
    printf '\n' >> "${MEMORY_PATH}"
  fi
}

HAS_COMPOSIO=false
if is_truthy "${HERMES_COMPOSIO_ENABLED:-}" && [ -n "${STARTER_TOKEN:-}" ] && [ -n "${COMPOSIO_MCP_URL}" ]; then
  HAS_COMPOSIO=true
fi
HAS_CRON=false
if command -v agent37 >/dev/null 2>&1; then
  HAS_CRON=true
fi

"${CLAUDE_BIN}" mcp remove composio -s user >/dev/null 2>&1 || true
if "${HAS_COMPOSIO}"; then
  "${CLAUDE_BIN}" mcp add --scope user --transport http composio "${COMPOSIO_MCP_URL}" \
    --header "Authorization: Bearer ${STARTER_TOKEN}" >/dev/null
  log "Composio MCP server registered for Claude Code."
else
  log "Composio MCP server not registered for Claude Code (enabled=${HERMES_COMPOSIO_ENABLED:-unset} token_set=$([ -n "${STARTER_TOKEN:-}" ] && echo yes || echo no) url_set=$([ -n "${COMPOSIO_MCP_URL}" ] && echo yes || echo no))."
fi

strip_composio_memory
if "${HAS_COMPOSIO}" || "${HAS_CRON}"; then
  ensure_trailing_newline
  printf '%s\n' "${MARKER_START}" >> "${MEMORY_PATH}"
fi

if "${HAS_COMPOSIO}"; then
  cat >> "${MEMORY_PATH}" <<'MEMORY'
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
  cat >> "${MEMORY_PATH}" <<'MEMORY'
## Recurring work

Agent37 runs schedules outside this container, so a firing wakes the machine to deliver its
prompt and it is free to sleep in between; a crontab (or systemd timer, or sleep loop) in here
stops the moment the machine sleeps. Use `agent37 cron add --schedule "0 9 * * 1-5" --prompt
"..." --timezone America/New_York`, plus `agent37 cron list|update|remove|runs`. The prompt
arrives as a fresh message in its own chat, so write it to stand on its own. Docs:
https://www.agent37.com/docs/agents-api/crons

MEMORY
fi

if "${HAS_COMPOSIO}" || "${HAS_CRON}"; then
  cat >> "${MEMORY_PATH}" <<'MEMORY'
(This section is managed by Agent37 and rewritten at every boot; edits inside it are lost.)
MEMORY
  printf '%s\n' "${MARKER_END}" >> "${MEMORY_PATH}"
  log "Managed guidance written to Claude Code memory (composio=${HAS_COMPOSIO} cron=${HAS_CRON})."
fi
