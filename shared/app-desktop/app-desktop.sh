# shellcheck shell=bash
# Consumer desktop stack (migration Piece 5a), sourced by the consumer wrapper entrypoints.
# TigerVNC's Xtigervnc replaces Xvfb as the X server: it implements RFB SetDesktopSize, so
# noVNC's resize=remote resizes the real framebuffer to the browser viewport (full-bleed, no
# letterbox) and openbox reflows the maximized windows on the RandR change. x11vnc (the B2C
# stack) cannot do this — its -xrandr only follows server-side changes. websockify serves the
# noVNC pages on DESKTOP_PORT and bridges to the VNC socket; -localhost -SecurityTypes None
# mirrors the B2C trust model (the edge signed URL is the only gate, like ttyd/File Browser).
# The caller defines log() and exports DISPLAY before sourcing.
# Every binary here is launched by absolute path: the image ENV PATH is customer-first, and
# these are managed processes, so a customer's `pip install websockify` into the persisted
# ~/.venv would otherwise replace the desktop the platform supervises.

DESKTOP_PORT="${AGENT37_DESKTOP_PORT:-6080}"
DESKTOP_VNC_PORT="${AGENT37_DESKTOP_VNC_PORT:-5900}"
DESKTOP_SCREEN_GEOMETRY="${AGENT37_SCREEN_GEOMETRY:-1440x900x24}"
DESKTOP_BACKGROUND_COLOR="${AGENT37_DESKTOP_BACKGROUND_COLOR:-#F6F1E8}"
DESKTOP_NOVNC_WEB_ROOT="${AGENT37_DESKTOP_NOVNC_WEB_ROOT:-/usr/share/novnc}"
DESKTOP_ASSETS_DIR=/usr/local/share/agent37-desktop
DESKTOP_WALLPAPER_PATH="${AGENT37_DESKTOP_WALLPAPER_PATH:-${DESKTOP_ASSETS_DIR}/wallpaper.jpg}"

xvnc_pid=""
desktop_openbox_pid=""
idesk_pid=""
tint2_pid=""
websockify_pid=""
wallpaper_pid=""

# ~/.idesktop is fully derived from the image assets: clear it first, or a migrated row's
# old B2C chromium.lnk (persisted in HOME) renders as a duplicate Browser icon.
apply_desktop_background() {
  if [ -f "${DESKTOP_WALLPAPER_PATH}" ] && [ -x /usr/bin/feh ]; then
    /usr/bin/feh --no-fehbg --bg-fill "${DESKTOP_WALLPAPER_PATH}" >/dev/null 2>&1 \
      || log "Warning: wallpaper apply failed; keeping solid background."
  fi
}

# resize=remote resizes the screen but the root pixmap does not rescale with it: re-fill
# the wallpaper whenever the dimensions change. Exits with its Xtigervnc.
watch_desktop_resize() {
  local last="" cur
  while kill -0 "${xvnc_pid}" 2>/dev/null; do
    cur="$(/usr/bin/xrandr --query 2>/dev/null | sed -n 's/.*current \([0-9]* x [0-9]*\).*/\1/p' | head -1)"
    if [ -n "${cur}" ] && [ "${cur}" != "${last}" ]; then
      [ -n "${last}" ] && apply_desktop_background
      last="${cur}"
    fi
    sleep 3
  done
}

ensure_desktop_icons() {
  install -m 0644 "${DESKTOP_ASSETS_DIR}/ideskrc" "${HOME}/.ideskrc"
  mkdir -p "${HOME}/.idesktop"
  rm -f "${HOME}/.idesktop/"*.lnk
  install -m 0644 "${DESKTOP_ASSETS_DIR}"/*.lnk "${HOME}/.idesktop/"
}

start_desktop_stack() {
  local display_num="${DISPLAY#:}"
  local geometry="${DESKTOP_SCREEN_GEOMETRY%x*}"
  local depth="${DESKTOP_SCREEN_GEOMETRY##*x}"
  rm -f "/tmp/.X${display_num}-lock" "/tmp/.X11-unix/X${display_num}" 2>/dev/null || true

  /usr/bin/Xtigervnc "${DISPLAY}" -geometry "${geometry}" -depth "${depth}" \
    -rfbport "${DESKTOP_VNC_PORT}" -localhost -SecurityTypes None -AlwaysShared \
    -desktop Agent37 -ac >/tmp/xvnc.log 2>&1 &
  xvnc_pid=$!

  # xsetroot doubles as the display-ready probe and paints the solid background (a solid root
  # color survives every SetDesktopSize resize; a wallpaper pixmap would not).
  local i=0
  until /usr/bin/xsetroot -solid "${DESKTOP_BACKGROUND_COLOR}" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "${i}" -ge 50 ]; then
      log "Display ${DISPLAY} not accepting connections after 10s; continuing anyway."
      break
    fi
    sleep 0.2
  done

  /usr/bin/openbox >/tmp/openbox.log 2>&1 &
  desktop_openbox_pid=$!

  apply_desktop_background
  watch_desktop_resize &
  wallpaper_pid=$!

  ensure_desktop_icons || log "Warning: desktop icons install failed; continuing."
  /usr/bin/idesk >/tmp/idesk.log 2>&1 &
  idesk_pid=$!

  # Taskbar: the only place a minimized window can be brought back from (openbox draws no
  # decorations). Excluded from the liveness check like idesk.
  /usr/bin/tint2 -c "${DESKTOP_ASSETS_DIR}/tint2rc" >/tmp/tint2.log 2>&1 &
  tint2_pid=$!

  /usr/bin/websockify --web "${DESKTOP_NOVNC_WEB_ROOT}" "${DESKTOP_PORT}" "localhost:${DESKTOP_VNC_PORT}" >/tmp/novnc.log 2>&1 &
  websockify_pid=$!

  log "Desktop up (xvnc=${xvnc_pid} openbox=${desktop_openbox_pid} idesk=${idesk_pid} tint2=${tint2_pid} websockify=${websockify_pid} port=${DESKTOP_PORT} display=${DISPLAY})"
}

# idesk is deliberately excluded (B2C parity): an icon-helper crash must not tear down the
# live VNC session and the browser window the agent may be driving.
desktop_stack_alive() {
  kill -0 "${xvnc_pid}" 2>/dev/null \
    && kill -0 "${desktop_openbox_pid}" 2>/dev/null \
    && kill -0 "${websockify_pid}" 2>/dev/null
}

stop_desktop_stack() {
  local pid
  for pid in "${wallpaper_pid}" "${websockify_pid}" "${tint2_pid}" "${idesk_pid}" "${desktop_openbox_pid}" "${xvnc_pid}"; do
    [ -n "${pid}" ] || continue
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  xvnc_pid=""
  desktop_openbox_pid=""
  idesk_pid=""
  tint2_pid=""
  websockify_pid=""
  wallpaper_pid=""
}

supervise_app_desktop() {
  local failures=0 started
  while true; do
    started=${SECONDS}
    start_desktop_stack
    while desktop_stack_alive; do
      sleep 5
    done
    stop_desktop_stack
    # A run that lasted a minute was healthy; only quick consecutive crashes count.
    if [ $((SECONDS - started)) -ge 60 ]; then failures=0; else failures=$((failures + 1)); fi
    if [ "${failures}" -ge 3 ]; then
      log "Desktop stack crashed 3 times consecutively. Leaving it down."
      return 0
    fi
    log "Desktop stack exited. Restarting in 5s (attempt ${failures}/3)..."
    sleep 5
  done
}
