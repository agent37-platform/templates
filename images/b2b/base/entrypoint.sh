#!/bin/bash
# The whole boot of agent37-base: the customer's hooks in the background, then the browser
# terminal in the foreground. The terminal restarts on its own, so a crash there never takes
# the sandbox and the customer's processes down with it.
set -u

log() {
  printf '%s [agent37-base] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

HOOKS_DIR="${HOME}/.agent37/hooks"
TERMINAL_PORT="${AGENT37_TERMINAL_PORT:-7681}"

# The two documented hooks, with the same timeouts as every other system template:
# post-image-update.sh on the first boot of a new image, post-restart.sh on every boot.
run_hooks() {
  local last_ref_path="${HOOKS_DIR}/.last-image-ref"
  local image_ref="${AGENT37_RUNTIME_IMAGE_REF:-}"
  if [ -n "${image_ref}" ] && [ -f "${HOOKS_DIR}/post-image-update.sh" ] \
      && [ "$(cat "${last_ref_path}" 2>/dev/null)" != "${image_ref}" ]; then
    log "Running post-image-update hook."
    if timeout 900 bash "${HOOKS_DIR}/post-image-update.sh"; then
      printf '%s\n' "${image_ref}" > "${last_ref_path}"
    else
      log "post-image-update hook failed; it will run again on the next boot."
    fi
  fi
  if [ -f "${HOOKS_DIR}/post-restart.sh" ]; then
    log "Running post-restart hook."
    timeout 300 bash "${HOOKS_DIR}/post-restart.sh" || log "post-restart hook failed."
  fi
}

run_hooks &

while true; do
  /usr/local/bin/ttyd -p "${TERMINAL_PORT}" -W -t rendererType=dom /bin/bash
  log "ttyd exited; restarting."
  sleep 1
done
