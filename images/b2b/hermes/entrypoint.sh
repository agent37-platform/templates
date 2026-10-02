#!/bin/bash
# Absolute, not /usr/bin/env bash: the image ENV PATH is customer-first (see set_runtime_path
# below), so `env bash` would resolve the supervisor's own interpreter out of a persisted
# customer directory before any of this file runs.
set -euo pipefail

log() {
  printf '%s [agent37-hermes] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# The control plane routes the bare instance URL to the template's default port
# and passes it as env; the gateway must bind exactly that port.
GATEWAY_PORT="${AGENT37_GATEWAY_PORT:-${OPENCLAW_GATEWAY_PORT:-3737}}"
HERMES_DASHBOARD_PORT="${AGENT37_HERMES_DASHBOARD_PORT:-9119}"
# Hermes binds the dashboard here on loopback; a socat relay re-exposes it on
# HERMES_DASHBOARD_PORT (see start_hermes_dashboard_relay).
HERMES_DASHBOARD_LOOPBACK_PORT="${AGENT37_HERMES_DASHBOARD_LOOPBACK_PORT:-19119}"
TERMINAL_PORT="${AGENT37_TERMINAL_PORT:-7681}"
FILEBROWSER_PORT="${AGENT37_FILEBROWSER_PORT:-8080}"
FILEBROWSER_ROOT="${AGENT37_FILEBROWSER_ROOT:-${HOME}}"
FILEBROWSER_DB_PATH="${AGENT37_FILEBROWSER_DB_PATH:-${HOME}/.agent37/filebrowser.db}"
DISPLAY="${DISPLAY:-:99}"
SCREEN_GEOMETRY="${AGENT37_SCREEN_GEOMETRY:-1440x900x24}"
BOOTSTRAP_BREW="${AGENT37_BOOTSTRAP_BREW:-true}"
# AGENT37_LLM_PROXY_URL / AGENT37_MANAGED_TOKEN are the documented names; the STARTER names are
# deprecated aliases still injected for older platform releases (docs/partial-starter-proxy-migration.md).
# Each managed service carries its own URL: never derive one by joining a path onto another's.
LLM_PROXY_URL="${AGENT37_LLM_PROXY_URL:-${AGENT37_STARTER_PROXY_URL:-}}"
STARTER_PROXY_URL="${AGENT37_STARTER_PROXY_URL:-}"
STARTER_TOKEN="${AGENT37_MANAGED_TOKEN:-${AGENT37_STARTER_TOKEN:-}}"
STARTER_MODEL_ID="${AGENT37_STARTER_MODEL_ID:-default}"
BRAVE_PROXY_URL="${AGENT37_BRAVE_PROXY_URL:-}"
HERMES_BRAVE_ENABLED="${AGENT37_HERMES_BRAVE_ENABLED:-true}"
HERMES_COMPOSIO_ENABLED="${AGENT37_HERMES_COMPOSIO_ENABLED:-true}"
HERMES_PERFLO_ENABLED="${AGENT37_HERMES_PERFLO_ENABLED:-true}"
# Dashboard runs by default in every image; set AGENT37_HERMES_DASHBOARD_ENABLED=false to skip it.
HERMES_DASHBOARD_ENABLED="${AGENT37_HERMES_DASHBOARD_ENABLED:-true}"
HERMES_ROOT="${HOME}/.hermes"
HERMES_ROOT_CONFIG_PATH="${HERMES_ROOT}/config.yaml"
# The home every Hermes process boots in: the root, or the sticky active profile's
# directory once resolve_hermes_home has read ${HERMES_ROOT}/active_profile.
HERMES_HOME_RESOLVED="${HERMES_ROOT}"
HERMES_CONFIG_PATH="${HERMES_ROOT_CONFIG_PATH}"
# Explicit profile selector for every supervised `hermes` command (see resolve_hermes_home).
HERMES_PROFILE_ARGS=(-p default)
HERMES_CONFIG_UPDATER_SCRIPT="/usr/local/lib/agent37/configure-hermes-config.py"
CLAUDE_CONFIG_UPDATER_SCRIPT="/usr/local/lib/agent37/configure-claude-config.sh"
CODEX_CONFIG_UPDATER_SCRIPT="/usr/local/lib/agent37/configure-codex-config.sh"
OPENCODE_CONFIG_UPDATER_SCRIPT="/usr/local/lib/agent37/configure-opencode-config.sh"
GROK_CONFIG_UPDATER_SCRIPT="/usr/local/lib/agent37/configure-grok-config.sh"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-/usr/local/lib/hermes/hermes-agent}"
HERMES_PYTHON="${HERMES_PYTHON:-${HERMES_AGENT_DIR}/venv/bin/python}"
GATEWAY_DIR="/usr/local/lib/agent37-gateway"
GATEWAY_HOME="${AGENT37_GATEWAY_HOME:-${HOME}/.agent37-gateway}"
GATEWAY_WORKSPACE_DIR="${GATEWAY_WORKSPACE_DIR:-${HOME}}"
PYTHON_VENV_PATH="${HOME}/.venv"
PYTHON_USER_BASE="${PYTHONUSERBASE:-${HOME}/.local}"
PYTHON_USER_BIN="${PYTHON_USER_BASE}/bin"
AGENT37_HOOKS_DIR="${AGENT37_HOOKS_DIR:-${HOME}/.agent37/hooks}"
AGENT37_POST_IMAGE_UPDATE_HOOK="${AGENT37_HOOKS_DIR}/post-image-update.sh"
AGENT37_POST_RESTART_HOOK="${AGENT37_HOOKS_DIR}/post-restart.sh"
AGENT37_LAST_IMAGE_REF_PATH="${AGENT37_HOOKS_DIR}/.last-image-ref"
AGENT37_RUNTIME_IMAGE_REF="${AGENT37_RUNTIME_IMAGE_REF:-}"
MAX_RETRIES=3
RETRY_DELAY=3

export DISPLAY

gateway_pid=""
hermes_gateway_pid=""
hermes_dashboard_pid=""
hermes_dashboard_relay_pid=""
ttyd_pid=""
filebrowser_pid=""
xvfb_pid=""
openbox_pid=""
RUNTIME_ENV_ASSIGNMENTS=()

is_truthy() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
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

# Hermes profiles are sticky: `hermes profile use <name>` writes the name to
# ${HERMES_ROOT}/active_profile, and every bare `hermes` invocation follows it (upstream
# hermes_cli/main.py reads the file whenever HERMES_HOME points at the root, and exits when
# it names a profile that does not exist). The agent37 gateway, the managed-config path, the
# pid cleanup and the terminal shell read HERMES_HOME directly instead, so resolve the profile
# once here, pin every process to the same home, and pass the supervised `hermes` commands an
# explicit `-p` so a pointer edited mid-run cannot move a watchdog-restarted gateway on its
# own: a switch takes effect on the next boot, which is what `hermes profile use` means for a
# gateway anywhere else too. Mirrors upstream: trimmed name, `default` or empty means the
# root, the on-disk id is lowercase [a-z0-9][a-z0-9_-]{0,63}, and profiles live under
# ${HERMES_ROOT}/profiles/<name>. A pointer at an invalid or missing profile boots the default
# profile explicitly (bare `hermes` in a shell still refuses until the pointer is fixed).
resolve_hermes_home() {
  local active_file="${HERMES_ROOT}/active_profile"
  local name profile_dir

  HERMES_HOME_RESOLVED="${HERMES_ROOT}"
  HERMES_PROFILE_ARGS=(-p default)
  if [ -f "${active_file}" ]; then
    name="$(cat "${active_file}" 2>/dev/null || true)"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    name="${name,,}"
    if [ -n "${name}" ] && [ "${name}" != "default" ]; then
      profile_dir="${HERMES_ROOT}/profiles/${name}"
      if ! [[ "${name}" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
        log "Warning: ${active_file} names an invalid profile; booting the default profile instead. Bare hermes commands refuse until the pointer is cleared: hermes -p default profile use default"
      elif [ ! -d "${profile_dir}" ]; then
        log "Warning: ${active_file} names profile '${name}' but ${profile_dir} does not exist; booting the default profile instead. Bare hermes commands refuse until the profile exists or the pointer is cleared: hermes -p default profile use default"
      else
        HERMES_HOME_RESOLVED="${profile_dir}"
        HERMES_PROFILE_ARGS=(-p "${name}")
      fi
    fi
  fi

  HERMES_CONFIG_PATH="${HERMES_HOME_RESOLVED}/config.yaml"
  if [ "${HERMES_HOME_RESOLVED}" = "${HERMES_ROOT}" ]; then
    log "Hermes home: ${HERMES_HOME_RESOLVED} (default profile)."
  else
    log "Hermes home: ${HERMES_HOME_RESOLVED} (active profile '${name}' via hermes profile use; restart the instance to switch)."
  fi
}

build_runtime_env_assignments() {
  RUNTIME_ENV_ASSIGNMENTS=(
    "HOME=${HOME}"
    "NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX}"
    "PYTHONUSERBASE=${PYTHON_USER_BASE}"
    "AGENT37_MANAGED_TOKEN=${STARTER_TOKEN}"
    "AGENT37_LLM_PROXY_URL=${LLM_PROXY_URL}"
    "AGENT37_STARTER_PROXY_URL=${STARTER_PROXY_URL}"
    "AGENT37_STARTER_TOKEN=${STARTER_TOKEN}"
    "AGENT37_BRAVE_PROXY_URL=${BRAVE_PROXY_URL}"
    "AGENT37_HERMES_BRAVE_ENABLED=${HERMES_BRAVE_ENABLED}"
    "AGENT37_HERMES_COMPOSIO_ENABLED=${HERMES_COMPOSIO_ENABLED}"
    "HERMES_HOME=${HERMES_HOME_RESOLVED}"
    "HERMES_CONFIG_PATH=${HERMES_CONFIG_PATH}"
    "HERMES_AGENT_DIR=${HERMES_AGENT_DIR}"
    "HERMES_PYTHON=${HERMES_PYTHON}"
    "DISPLAY=${DISPLAY}"
    "PATH=${PATH}"
  )
}

# The managed gateway and dashboard must run the baked CLI: migrated homes carry
# self-installed hermes in ~/.local/bin and ~/.venv/bin that shadow it via the customer-first
# PATH above (which the gateway's child shells still inherit, by design). The venv entry point
# is a Python console script whose shebang is already the absolute venv interpreter, so it
# needs no interpreter prefix (unlike openclaw_cmd, which prefixes /usr/local/bin/node).
# `env` is pinned too: bash resolves it through PATH before it ever applies the PATH=
# assignment below, so a bare `env` would re-open the hole this function exists to close.
# The profile selector goes AFTER the subcommand (Hermes pre-parses -p anywhere in argv), so
# the process cmdline keeps reading `hermes gateway run ...` for anything that matches on it.
hermes_cmd() {
  /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" /usr/local/lib/hermes/hermes-agent/venv/bin/hermes "$@" "${HERMES_PROFILE_ARGS[@]}"
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
    "${NPM_CONFIG_PREFIX}" \
    "${PYTHON_USER_BIN}" \
    "${HERMES_ROOT}" \
    "${GATEWAY_HOME}"
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

  if ! "${PYTHON_VENV_PATH}/bin/python" -m pip --version >/dev/null 2>&1; then
    log "pip missing in ${PYTHON_VENV_PATH}; bootstrapping with ensurepip."
    "${PYTHON_VENV_PATH}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
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

  # Templates are comments-only so the has-content guard in run_post_restart_hook
  # stays false until the user actually adds commands.
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
  if [ -z "${AGENT37_RUNTIME_IMAGE_REF}" ]; then
    return 0
  fi

  local previous_ref=""
  if [ -f "${AGENT37_LAST_IMAGE_REF_PATH}" ]; then
    previous_ref="$(cat "${AGENT37_LAST_IMAGE_REF_PATH}" 2>/dev/null || true)"
  fi

  if [ "${previous_ref}" = "${AGENT37_RUNTIME_IMAGE_REF}" ]; then
    return 0
  fi

  log "Runtime image changed (${previous_ref:-<unset>} -> ${AGENT37_RUNTIME_IMAGE_REF}); running post-image-update hook."
  if run_with_optional_timeout 900 bash "${AGENT37_POST_IMAGE_UPDATE_HOOK}"; then
    printf '%s\n' "${AGENT37_RUNTIME_IMAGE_REF}" > "${AGENT37_LAST_IMAGE_REF_PATH}"
  else
    log "post-image-update hook failed; it will retry on next restart/update."
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
  if ! is_truthy "${BOOTSTRAP_BREW}"; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1 || [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    return 0
  fi

  log "Homebrew not found; bootstrapping to /home/linuxbrew/.linuxbrew (one-time)..."
  sudo -n mkdir -p /home/linuxbrew >/dev/null 2>&1 || true
  sudo -n chown -R "$(id -u):$(id -g)" /home/linuxbrew >/dev/null 2>&1 || true

  export NONINTERACTIVE=1
  export HOMEBREW_NO_ANALYTICS=1
  export HOMEBREW_NO_ENV_HINTS=1

  /bin/bash -lc "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
}

configure_hermes_config_path() {
  local target_config_path="${1:-}"
  local tmp

  mkdir -p "$(dirname "${target_config_path}")"

  tmp="$(mktemp)"
  if ! HERMES_CONFIG_PATH="${target_config_path}" \
      STARTER_MODEL_ID="${STARTER_MODEL_ID}" \
      STARTER_PROXY_URL="${STARTER_PROXY_URL}" \
      STARTER_TOKEN="${STARTER_TOKEN}" \
      HERMES_BRAVE_ENABLED="${HERMES_BRAVE_ENABLED}" \
      HERMES_COMPOSIO_ENABLED="${HERMES_COMPOSIO_ENABLED}" \
      HERMES_PERFLO_ENABLED="${HERMES_PERFLO_ENABLED}" \
      "${HERMES_PYTHON}" "${HERMES_CONFIG_UPDATER_SCRIPT}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    log "Error: failed to update ${target_config_path} via ${HERMES_CONFIG_UPDATER_SCRIPT}."
    return 1
  fi

  mv "${tmp}" "${target_config_path}"
  log "Hermes config: wrote ${target_config_path} (starter_proxy_set=$(is_set "${STARTER_PROXY_URL}"))."
}

configure_hermes_config() {
  local status=0
  local profile_config_path
  local profiles_dir="${HERMES_ROOT}/profiles"

  # The base image does not bake the managed-config updater; leave Hermes
  # config alone so the user's own credentials are the only ones in play.
  if [ ! -f "${HERMES_CONFIG_UPDATER_SCRIPT}" ]; then
    log "No managed-config updater in this image; skipping Hermes config injection."
    return 0
  fi

  configure_hermes_config_path "${HERMES_ROOT_CONFIG_PATH}" || status=1

  # The home this boot runs in always gets the managed config, even a profile directory
  # that has no config.yaml yet (the writer creates it).
  if [ "${HERMES_CONFIG_PATH}" != "${HERMES_ROOT_CONFIG_PATH}" ]; then
    configure_hermes_config_path "${HERMES_CONFIG_PATH}" || status=1
  fi

  # Hermes profiles are isolated configs. Refresh existing profile configs too
  # so managed Agent37 credentials rotate consistently after restart/update,
  # whichever profile the instance boots in (resolve_hermes_home).
  if [ -d "${profiles_dir}" ]; then
    shopt -s nullglob
    for profile_config_path in "${profiles_dir}"/*/config.yaml; do
      [ "${profile_config_path}" = "${HERMES_CONFIG_PATH}" ] && continue
      configure_hermes_config_path "${profile_config_path}" || status=1
    done
    shopt -u nullglob
  fi

  return "${status}"
}

# Claude Code's managed config (the Composio MCP server, transcript retention) goes through
# Claude Code's own writers at every boot, like the Hermes updater above. Base images don't
# bake the script and leave Claude Code's config to the user.
configure_claude_config() {
  if [ ! -f "${CLAUDE_CONFIG_UPDATER_SCRIPT}" ]; then
    return 0
  fi
  STARTER_TOKEN="${STARTER_TOKEN}" HERMES_COMPOSIO_ENABLED="${HERMES_COMPOSIO_ENABLED}" \
    /bin/bash "${CLAUDE_CONFIG_UPDATER_SCRIPT}"
}

# Codex's managed config (the headless approval/sandbox seed plus the Composio MCP server) is
# regenerated at every boot the same way, but only on images that bake Codex and this updater
# (the consumer app image). Pure Hermes/base images ship neither, so the step is a no-op there;
# the updater self-skips again if the binary is missing. A customer's ChatGPT login lives in
# ~/.codex/auth.json (codex login --device-auth in the terminal) and is never touched here.
configure_codex_config() {
  if [ ! -f "${CODEX_CONFIG_UPDATER_SCRIPT}" ]; then
    return 0
  fi
  STARTER_TOKEN="${STARTER_TOKEN}" HERMES_COMPOSIO_ENABLED="${HERMES_COMPOSIO_ENABLED}" \
    CODEX_BIN="${CODEX_BIN:-/usr/local/bin/codex}" \
    /bin/bash "${CODEX_CONFIG_UPDATER_SCRIPT}"
}

# OpenCode's managed config (the managed Agent37 model + the Composio MCP server) is regenerated
# at every boot the same way, but only on images that bake OpenCode and this updater (the consumer
# app image). Pure Hermes/base images ship neither, so the step is a no-op there; the updater
# self-skips again if the binary is missing. OpenCode needs no account: the managed model (and its
# own free providers) work out of the box, and a customer's own provider key is read natively.
configure_opencode_config() {
  if [ ! -f "${OPENCODE_CONFIG_UPDATER_SCRIPT}" ]; then
    return 0
  fi
  STARTER_TOKEN="${STARTER_TOKEN}" LLM_PROXY_URL="${LLM_PROXY_URL}" \
    MANAGED_MODEL_ID="${STARTER_MODEL_ID}" COMPOSIO_MCP_URL="${AGENT37_COMPOSIO_MCP_URL:-}" \
    HERMES_COMPOSIO_ENABLED="${HERMES_COMPOSIO_ENABLED}" OPENCODE_BIN="${OPENCODE_BIN:-/usr/local/bin/opencode}" \
    /bin/bash "${OPENCODE_CONFIG_UPDATER_SCRIPT}"
}

# Grok's managed config (the Composio MCP server + the managed rules file) is regenerated at
# every boot the same way, but only on images that bake Grok and this updater (the consumer app
# image). Pure Hermes/base images ship neither, so the step is a no-op there; the updater
# self-skips again if the binary is missing. A customer's own xAI login (`grok login
# --device-code` in the terminal, or XAI_API_KEY) is never touched here.
configure_grok_config() {
  if [ ! -f "${GROK_CONFIG_UPDATER_SCRIPT}" ]; then
    return 0
  fi
  STARTER_TOKEN="${STARTER_TOKEN}" HERMES_COMPOSIO_ENABLED="${HERMES_COMPOSIO_ENABLED}" \
    GROK_BIN="${GROK_BIN:-/usr/local/bin/grok}" \
    /bin/bash "${GROK_CONFIG_UPDATER_SCRIPT}"
}

cleanup_stale_browser_locks() {
  local dir="${HOME}/.config/chromium"
  local lock_path

  if [ -d "${dir}" ]; then
    for lock_path in \
      "${dir}/SingletonCookie" \
      "${dir}/SingletonLock" \
      "${dir}/SingletonSocket" \
      "${dir}/Default/LOCK" \
      "${dir}/DevToolsActivePort"; do
      rm -f "${lock_path}" 2>/dev/null || true
    done
  fi

  rm -rf /tmp/org.chromium.Chromium.* 2>/dev/null || true
}

cleanup_stale_hermes_pid() {
  local pid_file="${HERMES_HOME_RESOLVED}/gateway.pid"
  local stale_pid

  [ -f "${pid_file}" ] || return 0

  stale_pid="$("${HERMES_PYTHON}" -c "import json,sys; print(json.load(open('${pid_file}'))['pid'])" 2>/dev/null || true)"

  if [ -n "${stale_pid}" ] && kill -0 "${stale_pid}" 2>/dev/null; then
    return 0
  fi

  rm -f "${pid_file}"
}

start_display() {
  /usr/bin/Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" -ac +extension RANDR &
  xvfb_pid=$!
  sleep 1
  /usr/bin/openbox >/tmp/openbox.log 2>&1 &
  openbox_pid=$!
  log "display up (xvfb=${xvfb_pid} openbox=${openbox_pid})"
}

start_hermes_gateway() {
  cleanup_stale_hermes_pid
  log "Starting hermes gateway daemon..."
  hermes_cmd gateway run --replace &
  hermes_gateway_pid=$!
}

start_hermes_dashboard() {
  log "Starting hermes dashboard (loopback ${HERMES_DASHBOARD_LOOPBACK_PORT}, exposed via relay on ${HERMES_DASHBOARD_PORT})..."
  hermes_cmd dashboard --host 127.0.0.1 --port "${HERMES_DASHBOARD_LOOPBACK_PORT}" --no-open --skip-build &
  hermes_dashboard_pid=$!
}

# Recent Hermes refuses a non-loopback dashboard bind unless an auth provider is
# registered, and on a loopback bind it enforces a Host allowlist (localhost/
# 127.0.0.1/::1; DNS-rebinding defence). We bind it to loopback and re-expose the
# routed port with an L7 relay that rewrites the Host header to 127.0.0.1, so the
# edge signed-URL / Bearer stays the only gate with no Hermes-side auth.
start_hermes_dashboard_relay() {
  log "Starting hermes dashboard relay (0.0.0.0:${HERMES_DASHBOARD_PORT} -> 127.0.0.1:${HERMES_DASHBOARD_LOOPBACK_PORT})..."
  # RELAY_REWRITE_ORIGIN=1: Hermes' WS guard rejects a non-loopback Origin too, not just Host (rationale in dashboard-relay.js).
  RELAY_LISTEN_PORT="${HERMES_DASHBOARD_PORT}" RELAY_TARGET_PORT="${HERMES_DASHBOARD_LOOPBACK_PORT}" RELAY_REWRITE_ORIGIN=1 \
    /usr/local/bin/node /usr/local/lib/agent37/dashboard-relay.js &
  hermes_dashboard_relay_pid=$!
}

start_ttyd() {
  log "Starting ttyd terminal (port=${TERMINAL_PORT})..."
  /usr/local/bin/ttyd -p "${TERMINAL_PORT}" -W -t rendererType=dom \
    /usr/bin/env "${RUNTIME_ENV_ASSIGNMENTS[@]}" bash &
  ttyd_pid=$!
}

# FileBrowser runs --noauth behind the edge (the signed URL / Bearer is the only gate). v2.61.0
# still needs a persisted default user so the SPA can mint its internal JWT under noauth, else it
# shows a login screen and 401s on /api/resources.
ensure_filebrowser_db_and_user_policy() {
  local db_dir
  db_dir="$(dirname "${FILEBROWSER_DB_PATH}")"
  mkdir -p "${FILEBROWSER_ROOT}" "${db_dir}"

  if [ ! -f "${FILEBROWSER_DB_PATH}" ]; then
    log "Initializing File Browser database at ${FILEBROWSER_DB_PATH}..."
    if ! /usr/local/bin/filebrowser config init \
      --database "${FILEBROWSER_DB_PATH}" \
      --root "${FILEBROWSER_ROOT}" \
      --auth.method noauth \
      >/dev/null; then
      log "Warning: failed to initialize File Browser database; continuing startup."
    fi
  fi

  if ! /usr/local/bin/filebrowser config set \
    --database "${FILEBROWSER_DB_PATH}" \
    --auth.method noauth \
    >/dev/null; then
    log "Warning: failed to enforce File Browser noauth mode; continuing with existing DB settings."
  fi

  if ! /usr/local/bin/filebrowser users update 1 \
    --database "${FILEBROWSER_DB_PATH}" \
    --lockPassword \
    --scope / \
    --perm.admin=false \
    --perm.download=true \
    --perm.create=true \
    --perm.delete=true \
    --perm.rename=true \
    --perm.modify=true \
    --perm.share=true \
    --perm.execute=true \
    >/dev/null 2>&1; then
    log "File Browser default user missing; creating noauth bootstrap user..."
    /usr/local/bin/filebrowser users add agent37 agent37-noauth-placeholder \
      --database "${FILEBROWSER_DB_PATH}" \
      --lockPassword \
      --scope / \
      --perm.admin=false \
      --perm.download=true \
      --perm.create=true \
      --perm.delete=true \
      --perm.rename=true \
      --perm.modify=true \
      --perm.share=true \
      --perm.execute=true \
      >/dev/null 2>&1 \
      || log "Warning: failed to create File Browser bootstrap user; continuing."
  fi
}

start_filebrowser() {
  log "Starting File Browser (port=${FILEBROWSER_PORT} root=${FILEBROWSER_ROOT} db=${FILEBROWSER_DB_PATH})..."
  ensure_filebrowser_db_and_user_policy
  /usr/local/bin/filebrowser \
    --address 0.0.0.0 \
    --port "${FILEBROWSER_PORT}" \
    --root "${FILEBROWSER_ROOT}" \
    --database "${FILEBROWSER_DB_PATH}" \
    --log stdout \
    --noauth &
  filebrowser_pid=$!
}

start_agent37_gateway() {
  log "Starting agent37 gateway (port=${GATEWAY_PORT} workspace=${GATEWAY_WORKSPACE_DIR})..."
  /usr/bin/env \
    "${RUNTIME_ENV_ASSIGNMENTS[@]}" \
    "PORT=${GATEWAY_PORT}" \
    "HOST=0.0.0.0" \
    "NODE_ENV=production" \
    "AGENT37_GATEWAY_HOME=${GATEWAY_HOME}" \
    "GATEWAY_WORKSPACE_DIR=${GATEWAY_WORKSPACE_DIR}" \
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
  kill_and_wait "${hermes_gateway_pid}"
  kill_and_wait "${hermes_dashboard_pid}"
  kill_and_wait "${hermes_dashboard_relay_pid}"
  kill_and_wait "${ttyd_pid}"
  kill_and_wait "${filebrowser_pid}"
  kill_and_wait "${openbox_pid}"
  kill_and_wait "${xvfb_pid}"
}

log "Booting (uid=$(id -u) gateway_port=${GATEWAY_PORT} dashboard_port=${HERMES_DASHBOARD_PORT} terminal_port=${TERMINAL_PORT} filebrowser_port=${FILEBROWSER_PORT} workspace=${GATEWAY_WORKSPACE_DIR} starter_proxy_url_set=$(is_set "${STARTER_PROXY_URL}") image_ref=${AGENT37_RUNTIME_IMAGE_REF:-<unset>})"

ensure_base_dirs
resolve_hermes_home
set_runtime_path
build_runtime_env_assignments
trap 'cleanup; exit 143' SIGTERM
trap 'cleanup; exit 130' SIGINT
ensure_python_venv || log "Warning: Python virtualenv init failed; continuing."
configure_hermes_config || log "Warning: Hermes config update failed; continuing with existing config."
configure_claude_config || log "Warning: Claude Code config update failed; continuing with existing config."
configure_codex_config || log "Warning: Codex config update failed; continuing with existing config."
configure_opencode_config || log "Warning: OpenCode config update failed; continuing with existing config."
configure_grok_config || log "Warning: Grok config update failed; continuing with existing config."
ensure_hooks
cleanup_stale_browser_locks
# Start the anchor (agent37-gateway, port 3737) first so the instance reports ready before
# the customer's hooks (post-update up to 900 s, post-restart up to 300 s) and ttyd/File
# Browser's synchronous bootstrap run: the host gives up probing the port after 120 s.
start_agent37_gateway
monitor_http_ready "agent37-gateway" "http://127.0.0.1:${GATEWAY_PORT}/v1/health" &
run_post_update_hook_if_needed
run_post_restart_hook
# The display stack ships only in images that bake the browser/desktop tools (base/full);
# the lean small image has no Xvfb/openbox, so skip it there.
if [ -x /usr/bin/Xvfb ] && [ -x /usr/bin/openbox ]; then
  start_display
else
  log "No display stack in this image; skipping Xvfb/openbox."
fi
start_hermes_gateway
if is_truthy "${HERMES_DASHBOARD_ENABLED}"; then
  start_hermes_dashboard
  start_hermes_dashboard_relay
else
  log "Hermes dashboard disabled for this image; skipping."
fi
start_ttyd
start_filebrowser

if is_truthy "${HERMES_DASHBOARD_ENABLED}"; then
  monitor_http_ready "hermes-dashboard" "http://127.0.0.1:${HERMES_DASHBOARD_PORT}/" &
fi
monitor_http_ready "filebrowser" "http://127.0.0.1:${FILEBROWSER_PORT}/" &

if is_truthy "${BOOTSTRAP_BREW}"; then
  ensure_homebrew &
fi

# The agent37 gateway is the anchor process: if it cannot stay up the container
# exits and Docker's restart policy takes over. Side services retry then stay down.
# Poll instead of `wait -n`: bash reaps background children as they exit, and
# bash 5.2's `wait -n <pids>` silently skips already-reaped pids, which can block
# the loop forever on a dead service. A 5s poll also makes the crash counters
# genuinely consecutive — every healthy tick resets them.
gateway_retries=0
hermes_gateway_retries=0
hermes_dashboard_retries=0
hermes_dashboard_relay_retries=0
ttyd_retries=0
filebrowser_retries=0
display_retries=0
while true; do
  sleep 5

  if ! kill -0 "${gateway_pid}" 2>/dev/null; then
    gateway_retries=$((gateway_retries + 1))
    if [ "${gateway_retries}" -gt "${MAX_RETRIES}" ]; then
      log "agent37 gateway crashed ${MAX_RETRIES} times consecutively. Exiting so Docker restarts the container."
      cleanup
      exit 1
    fi
    log "agent37 gateway exited. Restarting in ${RETRY_DELAY}s (attempt ${gateway_retries}/${MAX_RETRIES})..."
    sleep "${RETRY_DELAY}"
    start_agent37_gateway
  else
    gateway_retries=0
  fi

  if [ -n "${hermes_gateway_pid}" ] && ! kill -0 "${hermes_gateway_pid}" 2>/dev/null; then
    hermes_gateway_retries=$((hermes_gateway_retries + 1))
    if [ "${hermes_gateway_retries}" -gt "${MAX_RETRIES}" ]; then
      log "hermes gateway daemon crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      hermes_gateway_pid=""
    else
      log "hermes gateway daemon exited. Restarting in ${RETRY_DELAY}s (attempt ${hermes_gateway_retries}/${MAX_RETRIES})..."
      sleep "${RETRY_DELAY}"
      start_hermes_gateway
    fi
  else
    hermes_gateway_retries=0
  fi

  if [ -n "${hermes_dashboard_pid}" ] && ! kill -0 "${hermes_dashboard_pid}" 2>/dev/null; then
    hermes_dashboard_retries=$((hermes_dashboard_retries + 1))
    if [ "${hermes_dashboard_retries}" -gt "${MAX_RETRIES}" ]; then
      log "hermes dashboard crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      hermes_dashboard_pid=""
    else
      log "hermes dashboard exited. Restarting in ${RETRY_DELAY}s (attempt ${hermes_dashboard_retries}/${MAX_RETRIES})..."
      sleep "${RETRY_DELAY}"
      start_hermes_dashboard
    fi
  else
    hermes_dashboard_retries=0
  fi

  if [ -n "${hermes_dashboard_relay_pid}" ] && ! kill -0 "${hermes_dashboard_relay_pid}" 2>/dev/null; then
    hermes_dashboard_relay_retries=$((hermes_dashboard_relay_retries + 1))
    if [ "${hermes_dashboard_relay_retries}" -gt "${MAX_RETRIES}" ]; then
      log "hermes dashboard relay crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      hermes_dashboard_relay_pid=""
    else
      log "hermes dashboard relay exited. Restarting in ${RETRY_DELAY}s (attempt ${hermes_dashboard_relay_retries}/${MAX_RETRIES})..."
      sleep "${RETRY_DELAY}"
      start_hermes_dashboard_relay
    fi
  else
    hermes_dashboard_relay_retries=0
  fi

  if [ -n "${ttyd_pid}" ] && ! kill -0 "${ttyd_pid}" 2>/dev/null; then
    ttyd_retries=$((ttyd_retries + 1))
    if [ "${ttyd_retries}" -gt "${MAX_RETRIES}" ]; then
      log "ttyd crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      ttyd_pid=""
    else
      log "ttyd exited. Restarting in ${RETRY_DELAY}s (attempt ${ttyd_retries}/${MAX_RETRIES})..."
      sleep "${RETRY_DELAY}"
      start_ttyd
    fi
  else
    ttyd_retries=0
  fi

  if [ -n "${filebrowser_pid}" ] && ! kill -0 "${filebrowser_pid}" 2>/dev/null; then
    filebrowser_retries=$((filebrowser_retries + 1))
    if [ "${filebrowser_retries}" -gt "${MAX_RETRIES}" ]; then
      log "File Browser crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      filebrowser_pid=""
    else
      log "File Browser exited. Restarting in ${RETRY_DELAY}s (attempt ${filebrowser_retries}/${MAX_RETRIES})..."
      sleep "${RETRY_DELAY}"
      start_filebrowser
    fi
  else
    filebrowser_retries=0
  fi

  if [ -n "${xvfb_pid}" ] && { ! kill -0 "${xvfb_pid}" 2>/dev/null || ! kill -0 "${openbox_pid}" 2>/dev/null; }; then
    display_retries=$((display_retries + 1))
    if [ "${display_retries}" -gt "${MAX_RETRIES}" ]; then
      log "Display stack crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      kill_and_wait "${openbox_pid}"
      kill_and_wait "${xvfb_pid}"
      xvfb_pid=""
      openbox_pid=""
    else
      log "Display stack exited. Restarting in ${RETRY_DELAY}s (attempt ${display_retries}/${MAX_RETRIES})..."
      kill_and_wait "${openbox_pid}"
      kill_and_wait "${xvfb_pid}"
      sleep "${RETRY_DELAY}"
      start_display
    fi
  else
    display_retries=0
  fi
done
