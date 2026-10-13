#!/bin/bash
# dockerd in the foreground: when it dies the instance is dead, which is what makes a broken
# daemon show up as a crash loop instead of a quiet box nobody can use. The desktop, the
# terminal and the file manager are started beside it and each comes back on its own, so a
# crashed viewer never takes the machine with it.
set -euo pipefail

DESKTOP_PORT="${AGENT37_DESKTOP_PORT:-6080}"
VNC_PORT="${AGENT37_DESKTOP_VNC_PORT:-5900}"
TERMINAL_PORT="${AGENT37_TERMINAL_PORT:-7681}"
FILES_PORT="${AGENT37_FILEBROWSER_PORT:-8080}"
# A starting size only: noVNC asks for the browser window's dimensions as soon as it connects.
GEOMETRY="${AGENT37_SCREEN_GEOMETRY:-1440x900x24}"
DISPLAY_NUM=1

export DISPLAY=":${DISPLAY_NUM}"

respawn() {
  local log="$1"
  shift
  while true; do
    "$@" >"${log}" 2>&1 || true
    sleep 2
  done
}

# xfce4-panel asks, on a profile it has never seen, whether to use the default layout or an
# empty one, and the dialog sits on top of the desktop until somebody clicks it. $HOME is the
# durable disk, so this runs once per instance, not once per image.
seed_xfce_profile() {
  local dir="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
  mkdir -p "${dir}"
  [ -f "${dir}/xfce4-panel.xml" ] || cp /etc/xdg/xfce4/panel/default.xml "${dir}/xfce4-panel.xml"
}

# What the box can do, as three icons on an otherwise empty desktop. Seeded once (a deleted
# icon stays deleted) and executable, which is what xfdesktop needs to launch one directly.
seed_desktop_icons() {
  local stamp="${HOME}/.agent37/desktop-icons-seeded" app
  [ -f "${stamp}" ] && return 0
  mkdir -p "${HOME}/Desktop" "$(dirname "${stamp}")"
  for app in firefox xfce4-terminal thunar; do
    [ -f "/usr/share/applications/${app}.desktop" ] \
      && install -m 0755 "/usr/share/applications/${app}.desktop" "${HOME}/Desktop/"
  done
  touch "${stamp}"
}

# Xtigervnc is the X server and the VNC server in one, on loopback only: the edge's signed URL
# is the gate, exactly as it is for ttyd and FileBrowser. A stale lock from the last boot names
# a pid that can be alive again, and the server refuses to start while it is there.
start_desktop() {
  rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
  respawn /tmp/xvnc.log Xtigervnc "${DISPLAY}" \
    -geometry "${GEOMETRY%x*}" -depth "${GEOMETRY##*x}" \
    -rfbport "${VNC_PORT}" -localhost -SecurityTypes None -AlwaysShared -desktop Agent37 -ac &
  until xdpyinfo >/dev/null 2>&1; do sleep 1; done
  respawn /tmp/xfce.log dbus-run-session -- xfce4-session &
  respawn /tmp/novnc.log websockify --web /usr/share/novnc "${DESKTOP_PORT}" "localhost:${VNC_PORT}" &
}

# FileBrowser runs --noauth behind the edge, like every other image, and its database belongs
# on the durable disk with everything else the customer accumulates. noauth still mints its
# JWT for a stored user, so a database with none shows a login screen and 401s every read.
FILEBROWSER_DB="${HOME}/.agent37/filebrowser.db"
FILEBROWSER_USER_FLAGS=(--lockPassword --scope / --perm.admin=false --perm.download=true
  --perm.create=true --perm.delete=true --perm.rename=true --perm.modify=true
  --perm.share=true --perm.execute=true)

ensure_filebrowser_db() {
  mkdir -p "$(dirname "${FILEBROWSER_DB}")"
  [ -f "${FILEBROWSER_DB}" ] || filebrowser config init \
    --database "${FILEBROWSER_DB}" --root "${HOME}" --auth.method noauth >/dev/null
  filebrowser users update 1 --database "${FILEBROWSER_DB}" "${FILEBROWSER_USER_FLAGS[@]}" >/dev/null 2>&1 \
    || filebrowser users add agent37 agent37-noauth-placeholder \
         --database "${FILEBROWSER_DB}" "${FILEBROWSER_USER_FLAGS[@]}" >/dev/null 2>&1 \
    || echo "ubuntu: warning: File Browser user policy failed; continuing"
}

start_services() {
  ensure_filebrowser_db
  respawn /tmp/ttyd.log ttyd -p "${TERMINAL_PORT}" -W -t rendererType=dom bash &
  respawn /tmp/filebrowser.log filebrowser --address 0.0.0.0 --port "${FILES_PORT}" \
    --root "${HOME}" --database "${FILEBROWSER_DB}" --noauth &
}

# Docker's data MUST live on the durable disk. The instance's writable root is an overlayfs,
# and extracting an image layer onto one fails on the whiteout device nodes it has to create
# ("failed to convert whiteout file ...: operation not permitted"), so a data-root left at
# /var/lib/docker cannot even complete a pull. $HOME is the durable disk's mount point, and
# it is the same reason Agent37's own hosts keep dockerd's data-root off an overlay.
DATA="${AGENT37_DOCKER_DATA:-$HOME/docker}"
mkdir -p "$DATA" /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  printf '{\n  "data-root": "%s"\n}\n' "$DATA" > /etc/docker/daemon.json
fi

seed_xfce_profile
seed_desktop_icons
start_desktop
start_services

echo "ubuntu: desktop on ${DESKTOP_PORT}, terminal on ${TERMINAL_PORT}, files on ${FILES_PORT}; starting dockerd"
exec dockerd
