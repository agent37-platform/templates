#!/bin/bash
# Absolute, not /usr/bin/env bash: the image ENV PATH is customer-first (see set_runtime_path
# below), so `env bash` would resolve the supervisor's own interpreter out of a persisted
# customer directory before any of this file runs.
set -euo pipefail

log() {
  printf '%s [agent37-openclaw] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# The control plane routes the bare instance URL to the template's default port (3737) and passes it
# as AGENT37_GATEWAY_PORT; the agent37-gateway must bind exactly that. OpenClaw's own gateway is an
# internal detail on a fixed loopback port — we deliberately ignore the injected OPENCLAW_GATEWAY_PORT
# (the control plane sets it to the default port too, which would collide with the agent37-gateway).
GATEWAY_PORT="${AGENT37_GATEWAY_PORT:-3737}"
# 18789 is the edge-facing OpenClaw port (Control UI + responses). OpenClaw refuses a non-loopback
# (lan) bind unless a token/password is enforced, but we want the Control UI reachable in a browser
# with NO gateway credential (the edge signed URL / Bearer is the only gate, like ttyd and File
# Browser). So the gateway binds LOOPBACK on OPENCLAW_NATIVE_LOOPBACK_PORT (auth-exempt) and a small
# L7 relay re-exposes it on OPENCLAW_NATIVE_PORT, rewriting Host -> 127.0.0.1 for the gateway's
# loopback Host-allowlist (DNS-rebind defence). Mirrors the Hermes dashboard fix in #359.
OPENCLAW_NATIVE_PORT=18789
OPENCLAW_NATIVE_LOOPBACK_PORT="${OPENCLAW_NATIVE_LOOPBACK_PORT:-28789}"
DASHBOARD_RELAY_SCRIPT="${OPENCLAW_DASHBOARD_RELAY_SCRIPT:-/usr/local/lib/openclaw/dashboard-relay.js}"
TERMINAL_PORT="${AGENT37_TERMINAL_PORT:-7681}"
FILEBROWSER_PORT="${AGENT37_FILEBROWSER_PORT:-8080}"
FILEBROWSER_ROOT="${AGENT37_FILEBROWSER_ROOT:-${HOME}}"
FILEBROWSER_DB_PATH="${AGENT37_FILEBROWSER_DB_PATH:-${HOME}/.agent37/filebrowser.db}"
BOOTSTRAP_BREW="${AGENT37_BOOTSTRAP_BREW:-true}"

# Managed credentials arrive as AGENT37_MANAGED_TOKEN / AGENT37_LLM_PROXY_URL (the documented
# names; the STARTER names are deprecated aliases still injected for older platform releases —
# docs/partial-starter-proxy-migration.md). Map them onto the OPENCLAW_STARTER_* names the OpenClaw
# runtime and its managed plugins read.
# Each managed service carries its own URL: never derive one by joining a path onto another's.
LLM_PROXY_URL="${AGENT37_LLM_PROXY_URL:-${AGENT37_STARTER_PROXY_URL:-${OPENCLAW_STARTER_PROXY_URL:-}}}"
STARTER_PROXY_URL="${AGENT37_STARTER_PROXY_URL:-${OPENCLAW_STARTER_PROXY_URL:-}}"
BRAVE_PROXY_URL="${AGENT37_BRAVE_PROXY_URL:-${OPENCLAW_BRAVE_PROXY_URL:-}}"
STARTER_TOKEN="${AGENT37_MANAGED_TOKEN:-${AGENT37_STARTER_TOKEN:-${OPENCLAW_STARTER_TOKEN:-}}}"
STARTER_PROVIDER_ID="${OPENCLAW_STARTER_PROVIDER_ID:-agent37}"
STARTER_MODEL_ID="${AGENT37_STARTER_MODEL_ID:-${OPENCLAW_STARTER_MODEL_ID:-default}}"
MANAGED_PLUGIN_BRAVE_ENABLED="${AGENT37_MANAGED_PLUGIN_BRAVE_ENABLED:-true}"
MANAGED_PLUGIN_COMPOSIO_ENABLED="${AGENT37_MANAGED_PLUGIN_COMPOSIO_ENABLED:-true}"
MANAGED_PLUGIN_PERFLO_ENABLED="${AGENT37_MANAGED_PLUGIN_PERFLO_ENABLED:-true}"
# The instance's edge dashboard origin (https://<id>-18789.<domain>); when set, the config updater
# opens OpenClaw's Control UI on 18789 for this origin so the dashboard is usable in a browser.
CONTROL_UI_INSTANCE_ORIGIN="${OPENCLAW_CONTROL_UI_INSTANCE_ORIGIN:-}"

CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR}/openclaw.json}"
CONFIG_UPDATER_SCRIPT="${OPENCLAW_CONFIG_UPDATER_SCRIPT:-/usr/local/lib/openclaw/configure-openclaw-config.js}"
OPENCLAW_TOKEN=""

GATEWAY_DIR="/usr/local/lib/agent37-gateway"
GATEWAY_HOME="${AGENT37_GATEWAY_HOME:-${HOME}/.agent37-gateway}"
GATEWAY_WORKSPACE_DIR="${GATEWAY_WORKSPACE_DIR:-${HOME}}"
GATEWAY_DEFAULT_AGENT="${GATEWAY_DEFAULT_AGENT:-openclaw}"

PYTHON_VENV_PATH="${OPENCLAW_PYTHON_VENV:-${HOME}/.venv}"
PYTHON_USER_BASE="${PYTHONUSERBASE:-${HOME}/.local}"
PYTHON_USER_BIN="${PYTHON_USER_BASE}/bin"
AGENT37_HOOKS_DIR="${AGENT37_HOOKS_DIR:-${HOME}/.agent37/hooks}"
AGENT37_POST_IMAGE_UPDATE_HOOK="${AGENT37_HOOKS_DIR}/post-image-update.sh"
AGENT37_POST_RESTART_HOOK="${AGENT37_HOOKS_DIR}/post-restart.sh"
AGENT37_LAST_IMAGE_REF_PATH="${AGENT37_HOOKS_DIR}/.last-image-ref"
AGENT37_RUNTIME_IMAGE_REF="${AGENT37_RUNTIME_IMAGE_REF:-}"
MAX_RETRIES=3
RETRY_DELAY=3

openclaw_gateway_pid=""
openclaw_relay_pid=""
gateway_pid=""
ttyd_pid=""
filebrowser_pid=""
RUNTIME_ENV_ASSIGNMENTS=()

is_truthy() {
  local value
  value="$(printf '%s' "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_set() {
  [ -n "${1:-}" ] && printf 'yes' || printf 'no'
}

set_runtime_path() {
  PATH="${PYTHON_VENV_PATH}/bin:${PYTHON_USER_BIN}:${NPM_CONFIG_PREFIX}/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export PATH
}

build_runtime_env_assignments() {
  RUNTIME_ENV_ASSIGNMENTS=(
    "HOME=${HOME}"
    "NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX}"
    "PYTHONUSERBASE=${PYTHON_USER_BASE}"
    "OPENCLAW_STATE_DIR=${OPENCLAW_STATE_DIR}"
    "OPENCLAW_PYTHON_VENV=${PYTHON_VENV_PATH}"
    "OPENCLAW_GATEWAY_PORT=${OPENCLAW_NATIVE_LOOPBACK_PORT}"
    "OPENCLAW_STARTER_PROXY_URL=${STARTER_PROXY_URL}"
    "OPENCLAW_STARTER_TOKEN=${STARTER_TOKEN}"
    "OPENCLAW_STARTER_PROVIDER_ID=${STARTER_PROVIDER_ID}"
    "OPENCLAW_STARTER_MODEL_ID=${STARTER_MODEL_ID}"
    "AGENT37_MANAGED_TOKEN=${STARTER_TOKEN}"
    "AGENT37_LLM_PROXY_URL=${LLM_PROXY_URL}"
    "AGENT37_STARTER_PROXY_URL=${STARTER_PROXY_URL}"
    "AGENT37_STARTER_TOKEN=${STARTER_TOKEN}"
    "AGENT37_BRAVE_PROXY_URL=${BRAVE_PROXY_URL}"
    "OPENCLAW_BRAVE_PROXY_URL=${BRAVE_PROXY_URL}"
    "AGENT37_MANAGED_PLUGIN_COMPOSIO_ENABLED=${MANAGED_PLUGIN_COMPOSIO_ENABLED}"
    "PATH=${PATH}"
  )
}

# The managed gateway must run the baked CLI under the baked node: migrated homes carry
# ~/.npm-global openclaw installs and brew/nvm node that shadow them via the customer-first
# PATH above (which the gateway's child shells still inherit, by design). `env` is pinned for
# the same reason: bash resolves it through PATH before it ever applies the PATH= assignment
# below, so a bare `env` would re-open the hole this function exists to close.
openclaw_cmd() {
  /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" /usr/local/bin/node /usr/local/bin/openclaw "$@"
}

monitor_http_ready() {
  local name="${1:-}"
  local url="${2:-}"
  local start="${SECONDS}"
  local i=0

  while true; do
    i=$((i + 1))
    if curl -sS -o /dev/null --max-time 1 "${url}" >/dev/null 2>&1; then
      log "${name} ready: ${url} (after $((SECONDS - start))s)"
      return 0
    fi
    if [ $((i % 30)) -eq 0 ]; then
      log "${name} not ready yet: ${url} (elapsed $((SECONDS - start))s)"
    fi
    sleep 1
  done
}

ensure_base_dirs() {
  mkdir -p \
    "${HOME}" \
    "${OPENCLAW_STATE_DIR}" \
    "${NPM_CONFIG_PREFIX}" \
    "${PYTHON_USER_BIN}" \
    "${GATEWAY_HOME}" \
    "$(dirname "${FILEBROWSER_DB_PATH}")"
  sudo -n chown -R "$(id -u):$(id -g)" "${OPENCLAW_STATE_DIR}" >/dev/null 2>&1 || true
  sudo -n chown -R "$(id -u):$(id -g)" "${NPM_CONFIG_PREFIX}" >/dev/null 2>&1 || true
}

ensure_python_venv() {
  if [ -x "${PYTHON_VENV_PATH}/bin/python" ] \
      && ! "${PYTHON_VENV_PATH}/bin/python" -c 'import sys' >/dev/null 2>&1; then
    log "Existing Python virtualenv appears unhealthy; recreating ${PYTHON_VENV_PATH}."
    rm -rf "${PYTHON_VENV_PATH}"
  fi

  if [ ! -x "${PYTHON_VENV_PATH}/bin/python" ]; then
    log "Creating persistent Python virtualenv at ${PYTHON_VENV_PATH}..."
    /usr/bin/python3 -m venv "${PYTHON_VENV_PATH}"
  fi
}

run_with_optional_timeout() {
  local timeout_seconds="${1:-0}"
  local status=0
  shift

  set +e
  if [ "${timeout_seconds}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM "${timeout_seconds}" "$@"
    status=$?
  else
    "$@"
    status=$?
  fi
  set -e

  return "${status}"
}

ensure_hooks() {
  mkdir -p "${AGENT37_HOOKS_DIR}"
  if [ ! -f "${AGENT37_POST_IMAGE_UPDATE_HOOK}" ]; then
    cat > "${AGENT37_POST_IMAGE_UPDATE_HOOK}" <<'EOF'
#!/usr/bin/env bash
# Runs when the runtime image changes (for example after an instance update).
# Use this to reinstall tools that are not persisted in /home/node or /home/linuxbrew.
EOF
  fi
  if [ ! -f "${AGENT37_POST_RESTART_HOOK}" ]; then
    cat > "${AGENT37_POST_RESTART_HOOK}" <<'EOF'
#!/usr/bin/env bash
# Runs every time the container starts (restart, reboot, update, etc.).
# Use this to restore runtime state that doesn't survive container restarts.
EOF
  fi
  chmod 0755 "${AGENT37_POST_IMAGE_UPDATE_HOOK}" "${AGENT37_POST_RESTART_HOOK}" >/dev/null 2>&1 || true
}

run_post_update_hook_if_needed() {
  [ -n "${AGENT37_RUNTIME_IMAGE_REF}" ] || return 0

  local previous_ref=""
  if [ -f "${AGENT37_LAST_IMAGE_REF_PATH}" ]; then
    previous_ref="$(cat "${AGENT37_LAST_IMAGE_REF_PATH}" 2>/dev/null || true)"
  fi
  [ "${previous_ref}" = "${AGENT37_RUNTIME_IMAGE_REF}" ] && return 0

  log "Runtime image changed (${previous_ref:-<unset>} -> ${AGENT37_RUNTIME_IMAGE_REF}); running post-image-update hook."
  # OpenClaw 2026.7.1 rejects a divergent legacy update cache; shared SQLite is canonical.
  rm -f "${OPENCLAW_STATE_DIR}/update-check.json" 2>/dev/null || true
  # OpenClaw's own upgrade step: since 2026.8 the file-to-SQLite and workspace state migrations
  # are doctor-only and the gateway refuses to start until they have run, and plugins enabled
  # before 2026.8 have no capability consent on record, which also blocks the gateway.
  # `update repair` runs that doctor pass (--repair --non-interactive) and records the consent
  # in one go. Must run before start_openclaw_gateway (doctor refuses while a gateway owns the
  # state dir). Spelled out rather than via openclaw_cmd because timeout(1) cannot exec a
  # shell function.
  # Run it twice when the first pass fails: doctor checks that read the agent DB still see the
  # pre-upgrade schema in the same pass that upgraded it, and a second pass then completes.
  local doctor_ok=1
  run_with_optional_timeout 600 /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" \
      /usr/local/bin/node /usr/local/bin/openclaw update repair --accept-capabilities --yes </dev/null \
    || run_with_optional_timeout 600 /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" \
      /usr/local/bin/node /usr/local/bin/openclaw update repair --accept-capabilities --yes </dev/null \
    || { doctor_ok=0; log "openclaw update repair failed; it will retry on next restart/update."; }
  if run_with_optional_timeout 900 bash "${AGENT37_POST_IMAGE_UPDATE_HOOK}" && [ "${doctor_ok}" = 1 ]; then
    printf '%s\n' "${AGENT37_RUNTIME_IMAGE_REF}" > "${AGENT37_LAST_IMAGE_REF_PATH}"
  else
    log "post-image-update step failed; it will retry on next restart/update."
  fi
}

run_post_restart_hook() {
  if ! grep -qvE '^\s*(#|$)' "${AGENT37_POST_RESTART_HOOK}"; then
    return 0
  fi
  log "Running post-restart hook (${AGENT37_POST_RESTART_HOOK})."
  run_with_optional_timeout 300 bash "${AGENT37_POST_RESTART_HOOK}" \
    || log "post-restart hook failed; continuing startup."
}

ensure_homebrew() {
  is_truthy "${BOOTSTRAP_BREW}" || return 0
  if command -v brew >/dev/null 2>&1 || [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    return 0
  fi
  log "Homebrew not found; bootstrapping to /home/linuxbrew/.linuxbrew (one-time)..."
  sudo -n mkdir -p /home/linuxbrew >/dev/null 2>&1 || true
  sudo -n chown -R "$(id -u):$(id -g)" /home/linuxbrew >/dev/null 2>&1 || true
  export NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
  /bin/bash -lc "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
}

ensure_config_file() {
  mkdir -p "$(dirname "${CONFIG_PATH}")"
  [ -f "${CONFIG_PATH}" ] || printf '{}\n' > "${CONFIG_PATH}"
}

# Enable OpenClaw's OpenResponses endpoint + gateway token (so the agent37-gateway adapter can drive
# it), and inject the managed model/plugins when credentials are present. Then read the final token
# back so the adapter authenticates against the same value.
configure_openclaw_config() {
  local tmp meta_tmp generated_token
  ensure_config_file

  generated_token="$(/usr/bin/od -An -N24 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
  tmp="$(mktemp)"
  meta_tmp="$(mktemp)"
  if CONFIG_PATH="${CONFIG_PATH}" \
      META_PATH="${meta_tmp}" \
      GENERATED_GATEWAY_TOKEN="${generated_token}" \
      STARTER_PROVIDER_ID="${STARTER_PROVIDER_ID}" \
      STARTER_MODEL_ID="${STARTER_MODEL_ID}" \
      STARTER_PROXY_URL="${STARTER_PROXY_URL}" \
      STARTER_TOKEN="${STARTER_TOKEN}" \
      MANAGED_PLUGIN_BRAVE_ENABLED="${MANAGED_PLUGIN_BRAVE_ENABLED}" \
      MANAGED_PLUGIN_COMPOSIO_ENABLED="${MANAGED_PLUGIN_COMPOSIO_ENABLED}" \
      MANAGED_PLUGIN_PERFLO_ENABLED="${MANAGED_PLUGIN_PERFLO_ENABLED}" \
      CONTROL_UI_INSTANCE_ORIGIN="${CONTROL_UI_INSTANCE_ORIGIN}" \
      /usr/local/bin/node "${CONFIG_UPDATER_SCRIPT}" > "${tmp}"; then
    mv "${tmp}" "${CONFIG_PATH}"
    log "OpenClaw config: $(/usr/bin/jq -c '{responses:.responsesEndpointEnabled,starter:.starterProviderConfigured,controlUi:.controlUiOrigin,plugins:.activePlugins,composioMcp:.composioMcpConfigured,perfloMcp:.perfloMcpConfigured}' "${meta_tmp}" 2>/dev/null || printf '<written>')"
  else
    rm -f "${tmp}" >/dev/null 2>&1 || true
    log "Error: failed to update ${CONFIG_PATH} via ${CONFIG_UPDATER_SCRIPT}; continuing with existing config."
  fi
  rm -f "${meta_tmp}" >/dev/null 2>&1 || true

  OPENCLAW_TOKEN="$(/usr/bin/jq -r '.gateway.auth.token // empty' "${CONFIG_PATH}" 2>/dev/null || true)"
  log "OpenClaw gateway token resolved (set=$(is_set "${OPENCLAW_TOKEN}"))."
}

start_openclaw_gateway() {
  log "Starting OpenClaw gateway (loopback ${OPENCLAW_NATIVE_LOOPBACK_PORT}, exposed via relay on ${OPENCLAW_NATIVE_PORT})..."
  # Bind to loopback (127.0.0.1) so OpenClaw's "refusing to bind ... without auth" guard is exempt and
  # the gateway can run credential-free (auth.mode=none) -- the edge signed URL / Bearer is the only
  # gate, like ttyd and File Browser. The relay (start_openclaw_relay) re-exposes it on 0.0.0.0 for the
  # host proxy / edge. The agent37-gateway adapter talks to it directly over loopback (OPENCLAW_BASE_URL).
  # --allow-unconfigured lets the clean base image (no managed provider) still boot.
  openclaw_cmd gateway --bind loopback --port "${OPENCLAW_NATIVE_LOOPBACK_PORT}" --allow-unconfigured &
  openclaw_gateway_pid=$!
  log "openclaw gateway pid=${openclaw_gateway_pid}"
}

# The OpenClaw gateway binds loopback (so it can run credential-free behind the edge); this relay
# re-exposes it on 0.0.0.0:OPENCLAW_NATIVE_PORT for the host proxy / edge and rewrites the Host header
# to 127.0.0.1 so the gateway's loopback Host-allowlist (DNS-rebind defence) accepts it. HTTP + WS, no
# deps. The edge signed URL / Bearer stays the only gate. Mirrors the Hermes dashboard relay in #359.
start_openclaw_relay() {
  log "Starting OpenClaw gateway relay (0.0.0.0:${OPENCLAW_NATIVE_PORT} -> 127.0.0.1:${OPENCLAW_NATIVE_LOOPBACK_PORT})..."
  RELAY_LISTEN_PORT="${OPENCLAW_NATIVE_PORT}" RELAY_TARGET_PORT="${OPENCLAW_NATIVE_LOOPBACK_PORT}" \
    /usr/local/bin/node "${DASHBOARD_RELAY_SCRIPT}" &
  openclaw_relay_pid=$!
  log "openclaw gateway relay pid=${openclaw_relay_pid}"
}

start_ttyd() {
  log "Starting ttyd terminal (port=${TERMINAL_PORT})..."
  /usr/local/bin/ttyd -p "${TERMINAL_PORT}" -W -t rendererType=dom \
    /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" bash &
  ttyd_pid=$!
}

# FileBrowser runs --noauth behind the edge (the signed URL / Bearer is the only gate). v2.61.0 still
# needs a persisted default user so the SPA can mint its internal JWT under noauth.
ensure_filebrowser_db_and_user_policy() {
  local db_dir
  db_dir="$(dirname "${FILEBROWSER_DB_PATH}")"
  mkdir -p "${FILEBROWSER_ROOT}" "${db_dir}"

  if [ ! -f "${FILEBROWSER_DB_PATH}" ]; then
    log "Initializing File Browser database at ${FILEBROWSER_DB_PATH}..."
    /usr/local/bin/filebrowser config init --database "${FILEBROWSER_DB_PATH}" --root "${FILEBROWSER_ROOT}" --auth.method noauth >/dev/null \
      || log "Warning: failed to initialize File Browser database; continuing startup."
  fi

  /usr/local/bin/filebrowser config set --database "${FILEBROWSER_DB_PATH}" --auth.method noauth >/dev/null \
    || log "Warning: failed to enforce File Browser noauth mode; continuing."

  if ! /usr/local/bin/filebrowser users update 1 --database "${FILEBROWSER_DB_PATH}" --lockPassword --scope / \
      --perm.admin=false --perm.download=true --perm.create=true --perm.delete=true \
      --perm.rename=true --perm.modify=true --perm.share=true --perm.execute=true >/dev/null 2>&1; then
    log "File Browser default user missing; creating noauth bootstrap user..."
    /usr/local/bin/filebrowser users add agent37 agent37-noauth-placeholder --database "${FILEBROWSER_DB_PATH}" \
      --lockPassword --scope / --perm.admin=false --perm.download=true --perm.create=true \
      --perm.delete=true --perm.rename=true --perm.modify=true --perm.share=true --perm.execute=true >/dev/null 2>&1 \
      || log "Warning: failed to create File Browser bootstrap user; continuing."
  fi
}

start_filebrowser() {
  log "Starting File Browser (port=${FILEBROWSER_PORT} root=${FILEBROWSER_ROOT})..."
  ensure_filebrowser_db_and_user_policy
  /usr/local/bin/filebrowser --address 0.0.0.0 --port "${FILEBROWSER_PORT}" --root "${FILEBROWSER_ROOT}" \
    --database "${FILEBROWSER_DB_PATH}" --log stdout --noauth &
  filebrowser_pid=$!
}

start_agent37_gateway() {
  log "Starting agent37 gateway (port=${GATEWAY_PORT} default_agent=${GATEWAY_DEFAULT_AGENT} openclaw=$(is_set "${OPENCLAW_TOKEN}"))..."
  /usr/bin/env \
    "${RUNTIME_ENV_ASSIGNMENTS[@]}" \
    "PORT=${GATEWAY_PORT}" \
    "HOST=0.0.0.0" \
    "NODE_ENV=production" \
    "AGENT37_GATEWAY_HOME=${GATEWAY_HOME}" \
    "GATEWAY_WORKSPACE_DIR=${GATEWAY_WORKSPACE_DIR}" \
    "GATEWAY_DEFAULT_AGENT=${GATEWAY_DEFAULT_AGENT}" \
    "OPENCLAW_BASE_URL=http://127.0.0.1:${OPENCLAW_NATIVE_LOOPBACK_PORT}" \
    "OPENCLAW_TOKEN=${OPENCLAW_TOKEN}" \
    /usr/local/bin/node "${GATEWAY_DIR}/dist/server/server/index.js" &
  gateway_pid=$!
}

kill_and_wait() {
  local pid="${1:-}"
  [ -n "${pid}" ] || return 0
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

cleanup() {
  kill_and_wait "${gateway_pid}"
  kill_and_wait "${openclaw_gateway_pid}"
  kill_and_wait "${openclaw_relay_pid}"
  kill_and_wait "${ttyd_pid}"
  kill_and_wait "${filebrowser_pid}"
}

# supervise <pid_var> <retries_var> <name> <restart_fn> <is_anchor> <down_message>
# Restart a crashed service up to MAX_RETRIES, then give up. A non-anchor service nulls its
# pid and stays down; the anchor (agent37 gateway) exits the container so Docker's restart
# policy takes over. <name> labels the restart log line; <down_message> is logged verbatim
# when retries are exhausted.
supervise() {
  local -n _pid="$1"
  local -n _retries="$2"
  local name="$3" restart_fn="$4" is_anchor="$5" down_message="$6"

  [ -n "${_pid}" ] || return 0
  if kill -0 "${_pid}" 2>/dev/null; then
    _retries=0
    return 0
  fi

  _retries=$((_retries + 1))
  if [ "${_retries}" -gt "${MAX_RETRIES}" ]; then
    log "${down_message}"
    if is_truthy "${is_anchor}"; then
      cleanup
      exit 1
    fi
    _pid=""
    return 0
  fi

  log "${name} exited. Restarting in ${RETRY_DELAY}s (attempt ${_retries}/${MAX_RETRIES})..."
  sleep "${RETRY_DELAY}"
  "${restart_fn}"
}

log "Booting (uid=$(id -u) gateway_port=${GATEWAY_PORT} openclaw_port=${OPENCLAW_NATIVE_PORT} terminal_port=${TERMINAL_PORT} filebrowser_port=${FILEBROWSER_PORT} starter_proxy_url_set=$(is_set "${STARTER_PROXY_URL}") image_ref=${AGENT37_RUNTIME_IMAGE_REF:-<unset>})"

ensure_base_dirs
set_runtime_path
build_runtime_env_assignments
trap 'cleanup; exit 143' SIGTERM
trap 'cleanup; exit 130' SIGINT
ensure_python_venv || log "Warning: Python virtualenv init failed; continuing."
configure_openclaw_config
ensure_hooks
# Start the anchor (agent37-gateway, port 3737) first so the instance reports ready before
# the customer's hooks (post-update up to 900 s, post-restart up to 300 s) and ttyd/File
# Browser's synchronous bootstrap run: the host gives up probing the port after 120 s.
# The adapter reaches OpenClaw lazily.
start_agent37_gateway
monitor_http_ready "agent37-gateway" "http://127.0.0.1:${GATEWAY_PORT}/v1/health" &
run_post_update_hook_if_needed
run_post_restart_hook

start_openclaw_gateway
start_openclaw_relay
monitor_http_ready "openclaw-gateway" "http://127.0.0.1:${OPENCLAW_NATIVE_PORT}/health" &
start_ttyd
start_filebrowser
monitor_http_ready "filebrowser" "http://127.0.0.1:${FILEBROWSER_PORT}/" &

if is_truthy "${BOOTSTRAP_BREW}"; then
  ensure_homebrew &
fi

# The agent37 gateway is the anchor: if it cannot stay up the container exits and Docker's restart
# policy takes over. The OpenClaw gateway, ttyd, and File Browser retry a few times then stay down.
gateway_retries=0
openclaw_gateway_retries=0
openclaw_relay_retries=0
ttyd_retries=0
filebrowser_retries=0
while true; do
  sleep 5
  supervise gateway_pid gateway_retries "agent37 gateway" start_agent37_gateway true \
    "agent37 gateway crashed ${MAX_RETRIES} times consecutively. Exiting so Docker restarts the container."
  supervise openclaw_gateway_pid openclaw_gateway_retries "OpenClaw gateway" start_openclaw_gateway false \
    "OpenClaw gateway crashed ${MAX_RETRIES} times consecutively. Leaving it down; use the terminal to diagnose."
  supervise openclaw_relay_pid openclaw_relay_retries "OpenClaw gateway relay" start_openclaw_relay false \
    "OpenClaw gateway relay crashed ${MAX_RETRIES} times consecutively. Leaving it down; the dashboard will be unreachable until restart."
  supervise ttyd_pid ttyd_retries "ttyd" start_ttyd false \
    "ttyd crashed ${MAX_RETRIES} times consecutively. Leaving it down."
  supervise filebrowser_pid filebrowser_retries "File Browser" start_filebrowser false \
    "File Browser crashed ${MAX_RETRIES} times consecutively. Leaving it down."
done
