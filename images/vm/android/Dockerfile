# syntax=docker/dockerfile:1
# Agents API v1 (B2B) Android runtime, for `type: 'vm'` instances only. Backs the public
# agent37-android system template: the Android emulator, ADB, and a live screen in the
# browser, so a phone an agent can drive needs no customer setup at all. The emulator needs
# hardware virtualisation (`/dev/kvm`), which a real kernel has and a gVisor sandbox does
# not.
#
# What the entrypoint brings up, in order: dockerd, the AVD (created on first boot), a
# virtual display, x11vnc + noVNC on port 6901, then the emulator in the foreground.
#
# Bump = a new SDK, system image or package set: bump the tag in images.json and publish via
# scripts/publish-image.sh vm-android.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
# cmdline-tools 23.0, the current release. Check for a newer build number in
# https://dl.google.com/android/repository/repository2-1.xml (`cmdline-tools;latest`).
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-16111833_latest.zip
# Android 14 (API 34). `google_apis` ships Google Play services and keeps `adb root`;
# `google_apis_playstore` adds the Play Store app and drops root.
ARG SYSTEM_IMAGE="system-images;android-34;google_apis;x86_64"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip tini default-jre-headless \
        docker.io docker-compose-v2 kmod iproute2 webp \
        xvfb x11vnc novnc websockify openbox x11-utils \
        libgl1 libglu1-mesa libnss3 libpulse0 libasound2t64 libdbus-1-3 \
        libxcomposite1 libxcursor1 libxdamage1 libxi6 libxrandr2 libxtst6 \
        libxkbcommon-x11-0 libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:$PATH

RUN curl -fsSL "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" -o /tmp/clt.zip \
    && mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && unzip -q /tmp/clt.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/clt.zip

# The SDK lives in the image, not on the instance's disk: it is read-only at runtime and
# costs nothing against the disk you buy. The AVD is the opposite, and the entrypoint
# creates it under $HOME.
RUN yes | sdkmanager --licenses > /dev/null \
    && sdkmanager --install "platform-tools" "emulator" "${SYSTEM_IMAGE}" \
    && rm -rf "${ANDROID_HOME}/.temp" /root/.android

ENV ANDROID_SYSTEM_IMAGE="${SYSTEM_IMAGE}"
# noVNC's own page, so the instance URL opens the screen instead of a directory listing.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# The instance's one durable disk is mounted here, so the AVD (the phone's own storage) and
# dockerd's data-root both live under it and survive a restart, a resize and an image bump.
ENV HOME=/root
WORKDIR /root

COPY --chmod=0755 images/vm/android/entrypoint.sh /usr/local/bin/android-entrypoint.sh
COPY --chmod=0755 images/vm/android/android-wait /usr/local/bin/android-wait
COPY --chmod=0755 images/vm/android/android-shot /usr/local/bin/android-shot

ENTRYPOINT ["tini", "--", "/usr/local/bin/android-entrypoint.sh"]
