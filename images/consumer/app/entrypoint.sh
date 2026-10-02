#!/bin/bash
# Consumer wrapper around the b2b hermes entrypoint: supervise Minions Mission Control (the
# consumer product's primary Hermes surface) and the noVNC desktop (Piece 5a), then hand off
# to the untouched base entrypoint. Minions finds Hermes through the image's HERMES_AGENT_DIR /
# HERMES_PYTHON env and reads ~/.hermes/config.yaml per task. It also rewrites that file once
# at boot (skills dir registration), so it must not start until the base has finished its own
# config write — the agent37 gateway coming up on GATEWAY_PORT is the base's "config done"
# signal (the base starts it before the customer hooks and the harness, so it does not mean
# every service is up). The desktop owns DISPLAY: this image purges Xvfb, so the base
# entrypoint's display gate skips and the wrapper's Xtigervnc is the only :99 server (the
# agent's headed browser lands on it and becomes the visible desktop session).
# Absolute shebang, not /usr/bin/env bash: this is the container ENTRYPOINT and the image
# ENV PATH is customer-first, so `env bash` picks the wrapper's own interpreter out of a
# persisted customer directory.
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"

log() {
  printf '%s [agent37-app] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

GATEWAY_PORT="${AGENT37_GATEWAY_PORT:-${OPENCLAW_GATEWAY_PORT:-3737}}"
MINIONS_PORT="${AGENT37_MINIONS_PORT:-6969}"
MINIONS_HOME="${HOME}/.minions"
MINIONS_LOG_PATH="${MINIONS_HOME}/server.log"
MAX_RETRIES=3
RETRY_DELAY=5

supervise_minions() {
  local failures=0 started
  until /usr/bin/curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:${GATEWAY_PORT}/v1/health" >/dev/null 2>&1; do
    sleep 1
  done
  mkdir -p "${MINIONS_HOME}" || true
  while true; do
    log "Starting Minions Mission Control (port=${MINIONS_PORT} state=${MINIONS_HOME} log=${MINIONS_LOG_PATH})..."
    started=${SECONDS}
    # Baked node + baked CLI: minions is a node bin whose shebang is `env node`, so both the
    # script and its interpreter would otherwise resolve out of the customer-first PATH, and
    # `npm i -g minionsai` is a thing an agent is plausibly told to do to itself.
    PORT="${MINIONS_PORT}" MINIONS_HOME="${MINIONS_HOME}" DISPLAY="${DISPLAY:-:99}" \
      /usr/local/bin/node /usr/local/bin/minions >>"${MINIONS_LOG_PATH}" 2>&1 || true
    # A run that lasted a minute was healthy; only quick consecutive crashes count.
    if [ $((SECONDS - started)) -ge 60 ]; then failures=0; else failures=$((failures + 1)); fi
    if [ "${failures}" -ge "${MAX_RETRIES}" ]; then
      log "Minions Mission Control crashed ${MAX_RETRIES} times consecutively. Leaving it down."
      return 0
    fi
    log "Minions Mission Control exited. Restarting in ${RETRY_DELAY}s (attempt ${failures}/${MAX_RETRIES})..."
    sleep "${RETRY_DELAY}"
  done
}

supervise_minions &

# The desktop is a pro/max perk: the control plane sets AGENT_BROWSER_HEADED per tier on every
# create/recreate (agentInstances.ts), and the base image defaults it to 0. With the desktop
# skipped there is no X server at all (this image purges Xvfb), so a headed browser cannot
# start — the agent's browser tools run headless, same as the b2b hermes image.
if [ "${AGENT_BROWSER_HEADED:-0}" = "1" ]; then
  source /usr/local/lib/agent37/app-desktop.sh
  supervise_app_desktop &
else
  log "Desktop disabled (AGENT_BROWSER_HEADED=${AGENT_BROWSER_HEADED:-0})."
fi

exec /usr/local/bin/entrypoint.sh "$@"
