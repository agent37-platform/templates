#!/bin/sh
# Agent37 n8n entrypoint (POSIX sh: the hardened n8n image has no bash). Derives n8n's public
# URLs from the platform env, seeds the managed Agent37 model as an OpenAI-compatible credential
# on every boot (the managed token rotates on recreate), then hands off to n8n's own entrypoint.
set -eu

log() {
  printf '%s [agent37-n8n] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# The instance's public port: the control plane passes its URL as AGENT37_PUBLIC_URL (so a
# customer-chosen prefix or slug resolves correctly); the derivation covers the default
# n8n-{instanceId} prefix when the variable is absent.
if [ -z "${AGENT37_PUBLIC_URL:-}" ] && [ -n "${AGENT37_INSTANCE_ID:-}" ]; then
  AGENT37_PUBLIC_URL="https://n8n-${AGENT37_INSTANCE_ID}.${AGENT37_PUBLIC_DOMAIN:-agent37.app}"
fi
if [ -n "${AGENT37_PUBLIC_URL:-}" ]; then
  # Editor links, webhook URLs shown in the editor, and OAuth redirect URLs all come from these.
  export N8N_EDITOR_BASE_URL="${N8N_EDITOR_BASE_URL:-${AGENT37_PUBLIC_URL}}"
  export N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-${AGENT37_PUBLIC_URL}/}"
  export N8N_HOST="${N8N_HOST:-${AGENT37_PUBLIC_URL#https://}}"
  export N8N_PROTOCOL="${N8N_PROTOCOL:-https}"
fi

# The control plane routes the bare instance URL and the public port to the template's default
# port and passes it as AGENT37_GATEWAY_PORT; n8n must bind exactly that.
export N8N_PORT="${N8N_PORT:-${AGENT37_GATEWAY_PORT:-5678}}"
# TLS ends at the edge; requests reach n8n over plain HTTP one proxy hop away.
export N8N_PROXY_HOPS="${N8N_PROXY_HOPS:-1}"
# The editor's live updates. n8n checks a WebSocket handshake's Origin against the forwarded
# host, and the platform's proxy rewrites Host to the sandbox address, so that check can never
# pass here; the SSE backend accepts the browser's same-origin request instead.
export N8N_PUSH_BACKEND="${N8N_PUSH_BACKEND:-sse}"
export N8N_DIAGNOSTICS_ENABLED="${N8N_DIAGNOSTICS_ENABLED:-false}"
export N8N_VERSION_NOTIFICATIONS_ENABLED="${N8N_VERSION_NOTIFICATIONS_ENABLED:-false}"
export N8N_HIRING_BANNER_ENABLED="${N8N_HIRING_BANNER_ENABLED:-false}"

# The owner account, fixed from the creator's identity by the control plane: n8n's own sign-up
# page would hand the instance to whoever reached the public URL first. Applied on the first
# boot only (n8n locks an env-managed owner's profile, and instance env cannot change after
# create), so from then on the owner manages the account inside n8n like any self-hosted
# install. The stamp lands once n8n reports ready, so a boot that died before applying the
# owner tries again next time.
OWNER_STAMP="${HOME}/.n8n/.agent37-owner-seeded"
SEED_OWNER=false
if [ ! -f "${OWNER_STAMP}" ] && [ -n "${N8N_OWNER_EMAIL:-}" ] && [ -n "${N8N_OWNER_PASSWORD:-}" ]; then
  SEED_OWNER=true
  export N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true
  export N8N_INSTANCE_OWNER_EMAIL="${N8N_OWNER_EMAIL}"
  N8N_INSTANCE_OWNER_PASSWORD_HASH="$(node -e '
    process.stdout.write(require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs").hashSync(process.argv[1], 10));
  ' "${N8N_OWNER_PASSWORD}")"
  export N8N_INSTANCE_OWNER_PASSWORD_HASH
fi
unset N8N_OWNER_PASSWORD

# The managed Agent37 model as an OpenAI credential (the proxy is OpenAI-compatible: GET /models
# lists what it serves, so the OpenAI Chat Model node's picker works as-is). Imported by id on
# every boot so the rotated token lands and the customer's own edits to other credentials are
# untouched; before the owner signs up it lands in the owner's personal project, so it is there
# on first login. Import writes the SQLite database directly, so it runs before n8n starts.
seed_managed_model() {
  [ -n "${AGENT37_LLM_PROXY_URL:-}" ] && [ -n "${AGENT37_MANAGED_TOKEN:-}" ] || return 0
  seed_file="${HOME}/.n8n/.agent37-managed-model.json"
  mkdir -p "${HOME}/.n8n"
  node -e '
    const [url, apiKey] = process.argv.slice(1);
    process.stdout.write(JSON.stringify([{
      id: "agent37managed01",
      name: "Agent37 managed model",
      type: "openAiApi",
      data: { apiKey, url, organizationId: "", header: false },
    }]));
  ' "${AGENT37_LLM_PROXY_URL}" "${AGENT37_MANAGED_TOKEN}" > "${seed_file}"
  if n8n import:credentials --input="${seed_file}" >/dev/null 2>&1; then
    log "Managed model credential ready."
  else
    log "Could not seed the managed model credential; AI nodes need a credential added by hand."
  fi
  rm -f "${seed_file}"
}
seed_managed_model

if [ "${SEED_OWNER}" = true ]; then
  (
    until node -e 'fetch("http://127.0.0.1:'"${N8N_PORT}"'/healthz/readiness").then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))' 2>/dev/null; do
      sleep 2
    done
    touch "${OWNER_STAMP}"
    log "Owner account created for ${N8N_INSTANCE_OWNER_EMAIL}."
  ) &
fi

exec /docker-entrypoint.sh "$@"
