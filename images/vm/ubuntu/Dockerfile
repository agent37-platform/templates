# syntax=docker/dockerfile:1
# Agents API v1 (B2B) Ubuntu runtime, for `type: 'vm'` instances only: it needs a real
# kernel, so it cannot run as a gVisor sandbox. Backs the public agent37-ubuntu system
# template. Docker, Compose and buildx are installed and dockerd IS the entrypoint,
# so the customer SSHes in (or execs) and runs their own containers, compose stacks, k3s or
# emulator on a machine that behaves like any other Ubuntu box.
#
# It is also a machine you can look at: an XFCE desktop on 6080, a terminal on 7681 and a
# file manager on 8080, the same three services (and the same ports) every Agent37 harness
# image serves, so the dashboard gives the instance its Desktop, Terminal and Files buttons
# with no per-template handling. Nothing here is a gate: dockerd stays the foreground
# process, so the box lives or dies by the daemon and not by the desktop.
#
# Bump = a new Ubuntu base or package set: bump the tag in images.json, publish via
# scripts/publish-image.sh vm-ubuntu.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
# Deliberately nothing the platform already provides: sshd, the guest kernel and its module
# tree are mounted in read-only, so the image installs none of them.
#
# The desktop is Xtigervnc rather than Xvfb + x11vnc: it implements RFB SetDesktopSize, so
# the screen resizes to the browser window instead of letterboxing a fixed geometry.
# xfce4-screensaver is deliberately absent (and `--no-install-recommends` keeps it out): a
# lock screen on an account with no password is a box nobody can get back into.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        docker.io docker-compose-v2 docker-buildx \
        ca-certificates curl git kmod iproute2 less sudo tini \
        xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-terminal \
        thunar xfce4-appfinder exo-utils dbus-x11 \
        tigervnc-standalone-server novnc websockify x11-utils \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Firefox from Mozilla's own apt repo. Ubuntu's `chromium`/`firefox` packages are snap
# stubs, and snap does not run in a container at all, so a browser has to come from a
# first-party deb repo. Mozilla's is signed, tracks stable, and needs no root workaround
# (Chrome refuses to start as root without --no-sandbox, and this image is root).
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
         -o /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
         > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
         > /etc/apt/preferences.d/mozilla \
    && apt-get update \
    && apt-get install -y --no-install-recommends firefox \
    && rm -rf /var/lib/apt/lists/*

# The ttyd terminal (7681) and the FileBrowser file manager (8080), the same binaries and
# ports the harness images serve, so the dashboard's buttons work unchanged.
ARG TTYD_VERSION=1.7.7
ARG FILEBROWSER_VERSION=v2.63.23
ARG TARGETARCH
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
    && case "${arch}" in \
         amd64|x86_64) ttyd_arch="x86_64"; filebrowser_arch="amd64" ;; \
         arm64|aarch64) ttyd_arch="aarch64"; filebrowser_arch="arm64" ;; \
         *) echo "Unsupported arch: ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/ttyd \
         "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
    && chmod 0755 /usr/local/bin/ttyd \
    && curl -fsSL -o /tmp/filebrowser.tar.gz \
         "https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-${filebrowser_arch}-filebrowser.tar.gz" \
    && tar -xzf /tmp/filebrowser.tar.gz -C /tmp filebrowser \
    && install -m 0755 /tmp/filebrowser /usr/local/bin/filebrowser \
    && rm -f /tmp/filebrowser.tar.gz /tmp/filebrowser \
    && ttyd --version >/dev/null 2>&1 \
    && filebrowser version >/dev/null 2>&1

# noVNC's own page on /, connecting on load and sized to the browser window: the Desktop
# button opens a desktop, not a connect dialog. defaults.json is noVNC's documented way to
# set these, and the customer can still change them in its sidebar.
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && printf '{\n  "autoconnect": true,\n  "resize": "remote"\n}\n' > /usr/share/novnc/defaults.json

# The instance's one durable disk is mounted at the image's home directory, so HOME is also
# this image's declaration of what survives an image bump.
ENV HOME=/root
WORKDIR /root
COPY --chmod=0755 images/vm/ubuntu/entrypoint.sh /usr/local/bin/agent37-entrypoint.sh

ENTRYPOINT ["tini", "--", "/usr/local/bin/agent37-entrypoint.sh"]
