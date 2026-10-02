# syntax=docker/dockerfile:1
# Agents API v1 (B2B) OpenClaw runtime. One multi-stage build; the publish script pushes two targets:
#   base -> ghcr.io/agent37-platform/openclaw-base  Clean OpenClaw + the Agent37 gateway (chat adapter)
#           on 3737, OpenClaw's own gateway + Control UI (the dashboard) on 18789, terminal, file
#           browser, headless browser. No managed LLM injection, no agent37 integrations. The FROM
#           target for customer custom OpenClaw templates; the customer supplies model credentials.
#   full -> ghcr.io/agent37-platform/openclaw       The agent37-openclaw system template: base + the
#           agent37 Brave/Composio/environment plugins, driven by the platform's starter credentials.
#
# The agent surface is the uniform /v1/responses: the baked agent37-gateway (3737, the routable
# default port) proxies turns to OpenClaw's native gateway (18789) via its OpenClaw adapter, with
# GATEWAY_DEFAULT_AGENT=openclaw so callers never pass `agent`. 18789 also serves OpenClaw's Control
# UI (the dashboard), routed through the edge like the other ports. Headless: no desktop stack (the
# B2C image's noVNC/x11vnc/openbox/idesk/minions are all dropped here).
#
# Build context is docker/ so it shares shared/. Tag comes from docker/images.json; publish via
# scripts/publish-image.sh b2b-openclaw (pushes base and full at one tag).
#
# node:24 (not the B2C image's node:22): the baked agent37-gateway declares engines >=24, same as
# the B2B Hermes image. Verify OpenClaw installs clean on node:24 in the first host smoke test.
FROM node:24-bookworm AS base

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Core toolbelt only (no openbox/xvfb/x11/idesk/novnc desktop stack). fonts-liberation is kept for
# the headless browser; ffmpeg stays as a dormant CLI.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash ca-certificates curl git sudo \
    build-essential file \
    python3 python3-venv python3-pip python3-dev libffi-dev \
    vim nano less \
    jq ripgrep rsync \
    unzip xz-utils \
    procps lsof iproute2 \
    ffmpeg \
    fonts-liberation \
  && rm -rf /var/lib/apt/lists/* \
  && echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-node-nopasswd \
  && chmod 0440 /etc/sudoers.d/99-node-nopasswd \
  # Debian ships the node account locked ('!'), and sshd refuses locked accounts even for
  # pubkey auth; customer SSH lands as node. '*' = no password login, not locked.
  && usermod -p '*' node

# Preinstall uv so instruction-only Python skills that rely on `uv run`
# work immediately without waiting for optional Homebrew bootstrap.
ARG UV_VERSION=0.12.17
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh \
  && command -v uv >/dev/null 2>&1 \
  && uv --version

# Headless browser tool support: Playwright + a preinstalled Chromium bundle in /opt so a persisted
# home volume cannot mask it. No system chromium / desktop: the agent drives the browser headless.
ARG PLAYWRIGHT_VERSION=latest
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
  && mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}" \
  && playwright install-deps chromium \
  && playwright install chromium \
  && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"

# Install OpenClaw version globally so it keeps working when /home/node is a persisted volume.
# Pinned to 2026.9.4. 2026.9.5 and 9.6 crash-loop under gVisor (no openat2, openclaw/openclaw#152839,
# fixed in 9.7). 2026.9.7 boots, but fs-safe's no-clobber create uses renameat2(RENAME_NOREPLACE),
# which gets EINVAL on the sandbox's home mount and does not fall back, so every turn on a fresh
# state dir fails. Remove this pin once https://github.com/openclaw/fs-safe/issues/828 ships in an
# OpenClaw release. 9.7 also needs the 9p guard below at seven files.
ARG OPENCLAW_VERSION=2026.9.4
RUN echo "Installing OpenClaw ${OPENCLAW_VERSION}" \
  && curl -fsSL https://openclaw.ai/install.sh | bash -s -- \
    --install-method npm \
    --version "${OPENCLAW_VERSION}" \
    --no-onboard \
    --no-prompt \
  && command -v openclaw >/dev/null 2>&1 \
  && npm list -g openclaw --depth=0 | grep "openclaw@${OPENCLAW_VERSION}" \
  && npm cache clean --force

# OpenClaw >= 2026.8.1 treats a 9p filesystem as a cross-VM share and forces its SQLite
# databases into rollback journaling (readers block writers). Every mount inside a gVisor
# sandbox reports 9p, but it is a same-kernel passthrough, so WAL is safe there. Take 9p off
# the check; the virtiofs/nfs/smb guards stay. The bundler inlines the check into three dist files
# in 2026.9.4 (four as of 2026.9.5). Each edit must hit exactly once per file, so a future
# release that moves the code fails the build instead of silently shipping unpatched.
RUN set -eu; dist="$(npm root -g)/openclaw/dist"; \
  files="$(grep -rlE 'LINUX_V9FS_SUPER_MAGIC|CROSS_VM_FILESYSTEM_TYPES' "${dist}" | grep -v control-ui)"; \
  [ "$(printf '%s\n' ${files} | wc -l)" -eq 3 ] || { echo "expected 3 files with the 9p check, got: ${files}" >&2; exit 1; }; \
  for f in ${files}; do \
    for pat in 'LINUX_V9FS_SUPER_MAGIC ?= ?16914839' '\.startsWith\(["`]9p["`]\)' '["`]9p["`],' '["`]9p2000\.l["`]'; do \
      [ "$(grep -cE "${pat}" "${f}")" -eq 1 ] || { echo "pattern ${pat} not found exactly once in ${f}" >&2; exit 1; }; \
    done; \
    sed -i -E -e 's/LINUX_V9FS_SUPER_MAGIC ?= ?16914839/LINUX_V9FS_SUPER_MAGIC = -1/' \
      -e 's/([A-Za-z_$][A-Za-z0-9_$]*)\.startsWith\(["`]9p["`]\)/false/' \
      -e 's/["`]9p["`],//' -e 's/["`]9p2000\.l["`]//' "${f}"; \
    node --check "${f}"; \
  done

# Bake the Agent37 gateway (the per-instance chat adapter) from its release tag. It drives OpenClaw
# through the adapter, so the tag must be >= v0.1.3 (OpenClaw adapter + GATEWAY_DEFAULT_AGENT). It
# lives outside /home/node so the persisted volume cannot mask it; its state goes to
# ~/.agent37-gateway on the volume at runtime.
ARG GATEWAY_VERSION=v0.14.0
RUN git clone --depth 1 --branch "${GATEWAY_VERSION}" https://github.com/agent37-platform/gateway.git /usr/local/lib/agent37-gateway \
  && cd /usr/local/lib/agent37-gateway \
  && npm ci --no-audit --no-fund \
  && npm run build \
  && npm prune --omit=dev \
  && npm cache clean --force \
  && test -f dist/server/server/index.js

# Browser services reachable through the edge as signed URLs: the ttyd terminal (7681) and the
# FileBrowser file manager (8080).
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

# WhatsApp is an external plugin since 2026.9, and a sandbox that has to npm-install it mid-setup
# resolves the newest published version first, which is routinely ahead of the runtime we pin. Bake
# it at the runtime's own version so a customer's first connect starts at the QR and the CLI login
# has nothing left to download. It lives under the managed plugin dir so the config updater's stale
# -path healer owns it: an instance rolled back to an image without it has the load path stripped
# instead of booting a gateway that points at a plugin which is not there. Its dependencies sit in
# the project's node_modules, and the openclaw peer resolves from the global root above it.
RUN install -d -m 0755 /usr/local/lib/openclaw/plugins/whatsapp \
  && cd /usr/local/lib/openclaw/plugins/whatsapp \
  && npm init -y >/dev/null \
  && npm install --no-audit --no-fund "@openclaw/whatsapp@${OPENCLAW_VERSION}" \
  && npm cache clean --force \
  && test -f node_modules/@openclaw/whatsapp/openclaw.plugin.json \
  && test -f node_modules/@openclaw/whatsapp/dist/login-qr-api.js

# The config updater enables OpenClaw's OpenResponses endpoint + gateway token at boot (structural,
# needed for the adapter) and self-gates the managed model/plugins on what is baked, so it is a
# no-op for this clean base. The entrypoint self-gates each service on what the image provides.
RUN install -d -m 0755 /usr/local/lib/openclaw
COPY --chmod=0644 images/b2b/openclaw/configure-openclaw-config.js /usr/local/lib/openclaw/configure-openclaw-config.js
COPY --chmod=0644 shared/starter-catalog.js /usr/local/lib/openclaw/starter-catalog.js
COPY --chmod=0644 shared/dashboard-relay.js /usr/local/lib/openclaw/dashboard-relay.js
COPY --chmod=0755 images/b2b/openclaw/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/node
ENV OPENCLAW_STATE_DIR=${HOME}/.openclaw
ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global
ENV OPENCLAW_PYTHON_VENV=${HOME}/.venv
ENV PYTHONUSERBASE=${HOME}/.local
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV HOMEBREW_ALLOW_EUID=1
ENV AGENT_BROWSER_HEADED=0
ENV GATEWAY_DEFAULT_AGENT=openclaw

ENV PATH=${OPENCLAW_PYTHON_VENV}/bin:${PYTHONUSERBASE}/bin:${NPM_CONFIG_PREFIX}/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR ${HOME}

EXPOSE 3737 7681 8080 18789

USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Managed layer: the Agent37 Brave/environment plugins and Composio MCP configuration. Runtime
# starter credentials activate these integrations.
FROM base AS full

USER root

ENV AGENT37_MANAGED_INTEGRATIONS=1

RUN install -d -m 0755 \
    /usr/local/lib/openclaw/plugins/agent37-brave \
    /usr/local/lib/openclaw/plugins/agent37-environment
COPY --chmod=0644 shared/openclaw-plugins/agent37-brave/ /usr/local/lib/openclaw/plugins/agent37-brave/
COPY --chmod=0644 shared/openclaw-plugins/agent37-environment/ /usr/local/lib/openclaw/plugins/agent37-environment/

# The agent37 CLI: `cron` works on every instance, `expose` only on consumer ones (the
# starter endpoint 403s a B2B token). Managed stage only, so the clean base stays clean.
COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37

USER node
