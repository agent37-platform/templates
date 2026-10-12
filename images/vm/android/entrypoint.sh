#!/bin/bash
# The emulator runs in the foreground: when the phone dies the instance is dead, which is
# what makes a broken AVD show up as a crash loop instead of a quiet box nobody can use.
set -euo pipefail

AVD="${ANDROID_AVD_NAME:-agent37}"
DEVICE="${ANDROID_AVD_DEVICE:-pixel_6}"
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE}"
RAM_MB="${ANDROID_AVD_RAM_MB:-2048}"
DATA_MB="${ANDROID_AVD_DATA_MB:-6144}"
GEOMETRY="${ANDROID_SCREEN_GEOMETRY:-900x1800x24}"
DISPLAY_NUM=1

export ANDROID_AVD_HOME="${HOME}/.android/avd"
export DISPLAY=":${DISPLAY_NUM}"

respawn() {
  local log="$1"
  shift
  while true; do
    "$@" >"${log}" 2>&1 || true
    sleep 2
  done
}

# Docker's data MUST live on the durable disk: the writable root is an overlayfs, and
# extracting an image layer onto one fails on the whiteout device nodes it has to create.
# dockerd is a convenience here, not the point of the image, so it is backgrounded and its
# failure does not take the phone down with it.
start_dockerd() {
  mkdir -p "${HOME}/docker" /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    printf '{\n  "data-root": "%s"\n}\n' "${HOME}/docker" > /etc/docker/daemon.json
  fi
  respawn "${HOME}/dockerd.log" dockerd &
}

# The AVD is the phone's own storage, so it lives on the durable disk and is created once,
# on first boot. $HOME is a fresh disk at that point: nothing the image baked here survives.
create_avd() {
  mkdir -p "${ANDROID_AVD_HOME}"
  [ -f "${ANDROID_AVD_HOME}/${AVD}.ini" ] && return 0
  echo "android: creating AVD ${AVD} (${SYSTEM_IMAGE}, ${DEVICE})"
  avdmanager --silent create avd --name "${AVD}" --package "${SYSTEM_IMAGE}" \
    --device "${DEVICE}" --force
  local config="${ANDROID_AVD_HOME}/${AVD}.avd/config.ini"
  sed -i '/^hw\.ramSize=/d;/^disk\.dataPartition\.size=/d;/^hw\.keyboard=/d;/^hw\.gpu\./d' "${config}"
  cat >> "${config}" <<CONFIG
hw.ramSize=${RAM_MB}
disk.dataPartition.size=${DATA_MB}M
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
CONFIG
}

# The emulator asks, on every first boot, whether the operator really meant to run it under
# nested virtualisation, and the dialog sits on top of the screen until somebody clicks it.
# Everything here is nested by definition, so answer it once, in the file its own
# "Never show this again" writes.
seed_emulator_settings() {
  local conf="${HOME}/.config/Android Open Source Project/Emulator.conf"
  [ -f "${conf}" ] && return 0
  mkdir -p "$(dirname "${conf}")"
  printf '[General]\nshowNestedWarning=false\n' > "${conf}"
}

# x11vnc screencasts the display on loopback 5900 and websockify serves the noVNC client on
# 6901, the same pair every Agent37 desktop uses. Both come back if they exit, so a dropped
# viewer never needs an instance restart. A stale lock from the last boot names a pid that
# can be alive again, and Xvfb refuses to start while it is there.
start_screen() {
  rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
  respawn /tmp/xvfb.log Xvfb "${DISPLAY}" -screen 0 "${GEOMETRY}" -nolisten tcp &
  until xdpyinfo >/dev/null 2>&1; do sleep 1; done
  respawn /tmp/openbox.log openbox &
  respawn /tmp/x11vnc.log x11vnc -display "${DISPLAY}" -rfbport 5900 -localhost \
    -forever -shared -nopw -quiet &
  respawn /tmp/novnc.log websockify --web /usr/share/novnc 6901 localhost:5900 &
}

start_dockerd
create_avd
seed_emulator_settings
start_screen
adb start-server || true

echo "android: booting ${AVD}; run android-wait for the boot to complete"
exec emulator -avd "${AVD}" \
  -accel on -gpu swiftshader_indirect \
  -no-boot-anim -no-audio -no-metrics -camera-back none -camera-front none \
  -netdelay none -netspeed full \
  ${ANDROID_EMULATOR_ARGS:-}
