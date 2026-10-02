# syntax=docker/dockerfile:1
# Agents API v1 runtime images. One multi-stage build; the publish script pushes two of
# the three targets (core is internal, the shared ancestor):
#   core  -> (not published) Clean Hermes + the Agent37 gateway (chat adapter) on 3737, the
#            terminal and file browser, and the CLI toolbelt. NO browser/desktop stack.
#   base  -> ghcr.io/agent37-platform/hermes-base   Clean Hermes + gateway + browser/desktop.
#            The FROM target for customer custom templates; no managed LLM injection, no
#            agent37 integrations. Run locally it is plain Hermes; the customer
#            supplies LLM credentials.
#   full  -> ghcr.io/agent37-platform/hermes        The agent37-hermes system template:
#            base + managed starter-credential, Brave, and Composio configuration.
# Build context is the repo root so every stage shares shared/. Tags come from images.json;
# publish via scripts/publish-image.sh b2b-hermes (pushes base and full at one tag).
FROM node:24-bookworm AS core

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Core toolbelt only: no chromium/openbox/xvfb/x11/fonts (those are the browser+desktop
# stack, added in base). ffmpeg stays — it is a dormant CLI, not a resident memory cost.
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

# Keep Hermes outside /home/node because that path is mounted as a persisted volume.
# Pin the agent checkout as well as the installer script so builds do not float with main. Hermes Version
# Stamped image-managed (`.install_method`) so `hermes update` refuses in place: updates ship as a new image.
# The venv runs on a uv-managed Python (python-build-standalone bundles SQLite 3.53), never Debian's
# python3: bookworm's libsqlite3 is 3.40.1, which carries the WAL-reset corruption bug, so Hermes refuses
# WAL on every new database and `hermes doctor` flags the runtime. This is the same runtime repair
# `hermes update` performs on non-Docker installs; the install dir sits outside /home/node so the
# persisted volume cannot mask the interpreter. The version check fails the build if the installer ever
# falls back to the system interpreter.
ARG HERMES_VERSION=v2026.9.21
ARG UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
RUN install -d -o node -g node /usr/local/lib/hermes /home/node/.hermes /home/node/.local/bin "${UV_PYTHON_INSTALL_DIR}" \
  && touch /home/node/.bashrc \
  && chown node:node /home/node/.bashrc \
  && echo "Installing Hermes Agent ${HERMES_VERSION}" \
  && sudo -u node -H env HOME=/home/node SHELL=/bin/bash \
    UV_PYTHON_PREFERENCE=only-managed UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}" \
    bash -lc "curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_VERSION}/scripts/install.sh | bash -s -- --skip-setup --branch ${HERMES_VERSION} --dir /usr/local/lib/hermes/hermes-agent" \
  && ln -sf /usr/local/lib/hermes/hermes-agent/venv/bin/hermes /usr/local/bin/hermes \
  && echo docker > /usr/local/lib/hermes/hermes-agent/.install_method \
  && sudo -u node -H env HOME=/home/node /usr/local/bin/hermes --help >/dev/null 2>&1 \
  && /usr/local/lib/hermes/hermes-agent/venv/bin/python -c "import sqlite3, sys; sys.exit(f'venv SQLite {sqlite3.sqlite_version} has the WAL-reset bug (want 3.51.3+)') if sqlite3.sqlite_version_info < (3, 51, 3) else print('venv SQLite', sqlite3.sqlite_version, 'via', sys.base_prefix)" \
  && rm -rf /home/node/.cache /home/node/.npm /tmp/*

# Pre-bake the Telegram platform dep (match this HERMES_VERSION's tools/lazy_deps.py pin):
# Hermes lazy-installs it on first Telegram boot and the install races the adapter import,
# permanently wedging Telegram on any fresh-rootfs boot with it configured (hermes-agent
# issue #85272, "Any cannot be instantiated"). Remove once that issue is fixed upstream.
RUN uv pip install --python /usr/local/lib/hermes/hermes-agent/venv/bin/python "python-telegram-bot[webhooks]==22.8" \
  && /usr/local/lib/hermes/hermes-agent/venv/bin/python -c "import telegram, telegram.ext"

# Pre-build the Hermes dashboard web UI at image-build time so the runtime never runs `npm ci`
# (the default `hermes dashboard` build step). On the 1 vCPU / 2 GB lean tier that runtime build
# OOM-kills the container; baking the dist and launching with --skip-build avoids it and speeds
# boot on every tier. `npm run build` (tsc -b && vite build) emits to ../hermes_cli/web_dist per
# web/vite.config.ts, which --skip-build serves; node_modules is dropped after (not needed to serve).
RUN cd /usr/local/lib/hermes/hermes-agent/web \
  && sudo -u node -H env HOME=/home/node PATH=/usr/local/bin:/usr/bin:/bin sh -c 'npm ci --no-audit --no-fund && npm run build' \
  && test -d /usr/local/lib/hermes/hermes-agent/hermes_cli/web_dist \
  && rm -rf node_modules /home/node/.cache /home/node/.npm

# Bake the Agent37 gateway (the per-instance chat adapter) from its release tag.
# It lives outside /home/node so the persisted volume cannot mask it; its state
# (sqlite, logs) goes to ~/.agent37-gateway on the volume at runtime. --omit=optional
# skips the Claude Agent SDK's platform packages (a bundled Claude Code binary this
# image does not ship: the claude-code harness lives only in the consumer app image,
# which bakes the CLI on top of this one; here it reports agent_unavailable).
ARG GATEWAY_VERSION=v0.15.1
RUN git clone --depth 1 --branch "${GATEWAY_VERSION}" https://github.com/agent37-platform/gateway.git /usr/local/lib/agent37-gateway \
  && cd /usr/local/lib/agent37-gateway \
  && npm ci --no-audit --no-fund --omit=optional \
  && npm run build \
  && npm prune --omit=dev \
  && npm cache clean --force \
  && test -f dist/server/server/index.js \
  && out="$(env HOME=/tmp HERMES_AGENT_DIR=/usr/local/lib/hermes/hermes-agent \
    /usr/local/lib/hermes/hermes-agent/venv/bin/python server/workers/hermes_worker.py --self-test)" \
  && printf '%s\n' "$out" \
  && printf '%s' "$out" | grep -q '"ok": true'

# Platform awareness: this plugin injects persistent-path and hook context into
# the prompt and self-gates on what is installed, so it belongs in core.
COPY shared/hermes-plugins/agent37-environment/ /usr/local/lib/hermes/plugins/agent37-environment/
RUN uv pip install --python /usr/local/lib/hermes/hermes-agent/venv/bin/python /usr/local/lib/hermes/plugins/agent37-environment \
  && /usr/local/lib/hermes/hermes-agent/venv/bin/python - <<'PY'
import importlib.metadata

entry_points = importlib.metadata.entry_points()
if hasattr(entry_points, "select"):
    plugins = {ep.name for ep in entry_points.select(group="hermes_agent.plugins")}
else:
    plugins = {ep.name for ep in entry_points.get("hermes_agent.plugins", [])}

if "agent37-environment" not in plugins:
    raise SystemExit("missing Hermes plugin entry point: agent37-environment")
PY

ENV HOME=/home/node
ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global
ENV PYTHONUSERBASE=${HOME}/.local
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV HOMEBREW_ALLOW_EUID=1
ENV HERMES_AGENT_DIR=/usr/local/lib/hermes/hermes-agent
ENV HERMES_PYTHON=/usr/local/lib/hermes/hermes-agent/venv/bin/python
ENV GATEWAY_WORKSPACE_DIR=${HOME}

# Browser services reachable through the edge as signed URLs: the ttyd terminal (7681) and the
# FileBrowser file manager (8080). Late in the core stage: the downloads are independent of
# everything above, so they never bust their cache.
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

COPY --chmod=0755 images/b2b/hermes/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0644 shared/dashboard-relay.js /usr/local/lib/agent37/dashboard-relay.js

ENV PATH=${HOME}/.venv/bin:${PYTHONUSERBASE}/bin:${NPM_CONFIG_PREFIX}/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR ${HOME}

EXPOSE 3737 7681 8080

USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM core AS base

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Browser + desktop stack.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    chromium \
    openbox \
    x11-xserver-utils \
    xvfb \
    fonts-liberation \
  && rm -rf /var/lib/apt/lists/*

# Installing chromium pulls in xdg-utils and registers chromium.desktop as the system's
# link handler, so any CLI that wants to show the user a page (every `… login` command)
# silently launches a visible browser on a screen nobody is watching, and nothing ever
# closes it. Register a printer instead; /etc/xdg wins over the per-user file and lives
# outside the persisted home volume. The agent's browser and the desktop icon launch
# chromium directly and still work.
COPY --chmod=0755 shared/xdg/a37-show-url /usr/local/bin/a37-show-url
COPY --chmod=0644 shared/xdg/a37-show-url.desktop /usr/share/applications/a37-show-url.desktop
COPY --chmod=0644 shared/xdg/mimeapps.list /etc/xdg/mimeapps.list
RUN command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications || true

# Browser tool support: Playwright + a preinstalled Chromium browser bundle.
# We keep browsers in /opt so they are not masked by a persisted home volume.
ARG PLAYWRIGHT_VERSION=latest
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
  && mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}" \
  && playwright install-deps chromium \
  && playwright install chromium \
  && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"

# agent-browser: the CLI behind Hermes' built-in browser_* tools, pointed at the image's
# Chromium so it never downloads Chrome for Testing. Without it Hermes defaults to the
# Browser Use CLI (runnable via the baked uvx), whose only path in a sandbox is their paid
# cloud browser — 402 for every customer. --no-sandbox matches the desktop launcher:
# Chromium's own sandbox cannot start under gVisor.
# /usr/local, not the image's NPM_CONFIG_PREFIX: that points into /home/node, which the
# persisted home volume masks at runtime.
ARG AGENT_BROWSER_VERSION=0.38.1
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g "agent-browser@${AGENT_BROWSER_VERSION}" \
  && /usr/local/bin/agent-browser --version
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium
ENV AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"

# Headless: nothing renders the display. B2B has no desktop port at all, and on the consumer
# images the desktop is opened so rarely that a visible browser only ever painted for nobody.
# The control plane overrides this to 1 for pro/max subscription instances (live browser).
ENV AGENT_BROWSER_HEADED=0

EXPOSE 9119

USER node

FROM base AS full

USER root

ENV AGENT37_MANAGED_INTEGRATIONS=1

# Managed integrations: Brave search + Composio, driven by the platform's
# starter credentials passed as env at runtime.
COPY shared/hermes-plugins/agent37-brave/ /usr/local/lib/hermes/plugins/agent37-brave/
RUN uv pip install --python /usr/local/lib/hermes/hermes-agent/venv/bin/python /usr/local/lib/hermes/plugins/agent37-brave \
  && /usr/local/lib/hermes/hermes-agent/venv/bin/python - <<'PY'
import importlib.metadata

entry_points = importlib.metadata.entry_points()
if hasattr(entry_points, "select"):
    plugins = {ep.name for ep in entry_points.select(group="hermes_agent.plugins")}
else:
    plugins = {ep.name for ep in entry_points.get("hermes_agent.plugins", [])}

required = {"agent37-brave", "agent37-environment"}
missing = required - plugins
if missing:
    raise SystemExit(f"missing Hermes plugin entry points: {sorted(missing)}")
PY

# Managed LLM injection: the entrypoint runs this updater at boot to point Hermes
# at the platform's starter-credential proxy. Its absence is what makes base
# clean — the entrypoint skips the step when the file is not baked.
RUN install -d -m 0755 /usr/local/lib/agent37
COPY --chmod=0644 shared/configure-hermes-config.py /usr/local/lib/agent37/configure-hermes-config.py

# The agent37 CLI: `cron` works on every instance, `expose` only on consumer ones (the
# starter endpoint 403s a B2B token). Managed stage only, so the clean base stays clean.
COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37
RUN install -d -m 0755 /usr/local/lib/hermes/skills/agent37-cron
COPY --chmod=0644 shared/hermes-skills/agent37-cron/SKILL.md /usr/local/lib/hermes/skills/agent37-cron/SKILL.md

USER node
