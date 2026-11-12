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
# Hermes itself is upstream's own Docker build; the core stage copies it in and says why. The
# environment's python link is pointed at Hermes's bundled interpreter directly (upstream routes it
# through /usr/local/bin/python3, which would put its Python ahead of Debian's on PATH here), and
# the environment is handed to node (uid 1000) so `uv pip install --python "$HERMES_PYTHON"`
# still works; the rest of the tree stays root's and read-only, as upstream ships it.
ARG HERMES_VERSION=v0.23.1
FROM nousresearch/hermes-agent:${HERMES_VERSION} AS hermes
RUN ln -sfn "$(readlink -f /opt/hermes/.venv/bin/python)" /opt/hermes/.venv/bin/python \
  && chown -R 1000:1000 /opt/hermes/.venv

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

# Preinstall uv so instruction-only Python skills that rely on `uv run` work immediately.
ARG UV_VERSION=0.12.22
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh \
  && command -v uv >/dev/null 2>&1 \
  && uv --version

# Hermes is upstream's own Docker build, copied whole from its published image: the full source
# tree, the Python environment beside it with every messaging platform already in, Hermes's own
# Python, Node and browser under tools/, and the manifest that binds them. It is the one layout
# Hermes supports with its home on a separate volume, because nothing it needs to start lives under
# $HERMES_HOME: its dashboard can restart the gateway, the chat tab and the WhatsApp bridge find
# their files, and connecting a platform never swaps in an environment without the rest. The
# desktop installer this replaced keys all of that on the home it was run under, which here is
# never the home an instance boots with. It lives outside /home/node, which is the persisted
# volume. `hermes update` refuses in place (the tree is stamped docker): updates ship as a new
# image. /usr/local/lib/hermes/hermes-agent and its venv/ are the paths images before 2026.11.12b
# used, kept as links. PyYAML is for configure-hermes-config.py, which runs on this environment.
# The version check fails the build if the environment ever lands on the system interpreter.
COPY --from=hermes /opt/hermes /opt/hermes
ENV HERMES_RUNTIME_DIR=/opt/hermes/tools
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
RUN ln -s /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes \
  && ln -s .venv /opt/hermes/venv \
  && install -d -m 0755 /usr/local/lib/hermes \
  && ln -s /opt/hermes /usr/local/lib/hermes/hermes-agent \
  && install -d -o node -g node /home/node/.hermes \
  && test -f /opt/hermes/hermes_cli/web_dist/index.html \
  && test -f /opt/hermes/ui-tui/dist/entry.js \
  && test -f /opt/hermes/scripts/whatsapp-bridge/bridge.js \
  && sudo -u node -H env HOME=/home/node hermes --version \
  && uv pip install --python /opt/hermes/.venv/bin/python "pyyaml==6.0.3" \
  && /usr/local/lib/hermes/hermes-agent/venv/bin/python -c "import telegram, telegram.ext, yaml, slack_bolt, slack_sdk, discord, mcp.client.streamable_http" \
  && /opt/hermes/.venv/bin/python -c "import sqlite3, sys; sys.exit(f'venv SQLite {sqlite3.sqlite_version} has the WAL-reset bug (want 3.51.3+)') if sqlite3.sqlite_version_info < (3, 51, 3) else print('venv SQLite', sqlite3.sqlite_version, 'via', sys.base_prefix)" \
  && rm -rf /home/node/.cache /root/.cache /tmp/*

# Bake the Agent37 gateway (the per-instance chat adapter) from its release tag.
# It lives outside /home/node so the persisted volume cannot mask it; its state
# (sqlite, logs) goes to ~/.agent37-gateway on the volume at runtime. --omit=optional
# skips the Claude Agent SDK's platform packages (a bundled Claude Code binary this
# image does not ship: the claude-code harness lives only in the consumer app image,
# which bakes the CLI on top of this one; here it reports agent_unavailable).
ARG GATEWAY_VERSION=v0.18.1
RUN git clone --depth 1 --branch "${GATEWAY_VERSION}" https://github.com/agent37-platform/gateway.git /usr/local/lib/agent37-gateway \
  && cd /usr/local/lib/agent37-gateway \
  && npm ci --no-audit --no-fund --omit=optional \
  && npm run build \
  && npm prune --omit=dev \
  && npm cache clean --force \
  && test -f dist/server/server/index.js \
  && out="$(env HOME=/tmp HERMES_AGENT_DIR=/opt/hermes \
    /opt/hermes/.venv/bin/python server/workers/hermes_worker.py --self-test)" \
  && printf '%s\n' "$out" \
  && printf '%s' "$out" | grep -q '"ok": true'

# Platform awareness: this plugin injects persistent-path and hook context into
# the prompt and self-gates on what is installed, so it belongs in core.
COPY shared/hermes-plugins/agent37-environment/ /usr/local/lib/hermes/plugins/agent37-environment/
RUN uv pip install --python /opt/hermes/.venv/bin/python /usr/local/lib/hermes/plugins/agent37-environment \
  && /opt/hermes/.venv/bin/python - <<'PY'
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
ENV HERMES_AGENT_DIR=/opt/hermes
ENV HERMES_PYTHON=/opt/hermes/.venv/bin/python
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
# COPY --chmod would apply 0644 to a parent it creates, and node could not enter it.
RUN install -d -m 0755 /usr/local/lib/agent37
COPY --chmod=0644 shared/dashboard-relay.js /usr/local/lib/agent37/dashboard-relay.js

ENV PATH=${HOME}/.venv/bin:${PYTHONUSERBASE}/bin:${NPM_CONFIG_PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# Hermes drives the browser itself (browser_exec; agent-browser and the built-in browser_* tools
# left in v0.22.6) with the Chromium build it ships under /opt/hermes/tools, so it never downloads
# one, and it stays headless and adds --no-sandbox by itself in a container (Chromium's own sandbox
# cannot start under gVisor). This file is what it falls back to when that build is missing.
RUN install -d -m 0755 /etc/hermes \
  && printf '%s' /usr/bin/chromium > /etc/hermes/chromium-executable-path \
  && test -x "$(cat /etc/hermes/chromium-executable-path)"

# A login shell, which is what the agent's own terminal runs and what an SSH session is, starts
# from Debian's default PATH, and Hermes then appends what its own process had, its launcher and
# environment directories first. The customer's directories go in ahead of those, so `python` and
# anything installed into ~/.venv resolve to the customer's copy, never to Hermes's environment.
RUN printf '%s\n' 'PATH="$PATH:$HOME/.venv/bin:$HOME/.local/bin:$HOME/.npm-global/bin"' > /etc/profile.d/agent37-path.sh

EXPOSE 9119

USER node

FROM base AS full

USER root

ENV AGENT37_MANAGED_INTEGRATIONS=1

# Managed integrations: Brave search + Composio, driven by the platform's
# starter credentials passed as env at runtime.
COPY shared/hermes-plugins/agent37-brave/ /usr/local/lib/hermes/plugins/agent37-brave/
RUN uv pip install --python /opt/hermes/.venv/bin/python /usr/local/lib/hermes/plugins/agent37-brave \
  && /opt/hermes/.venv/bin/python - <<'PY'
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
COPY --chmod=0644 shared/configure-hermes-config.py /usr/local/lib/agent37/configure-hermes-config.py

# The agent37 CLI: `cron` works on every instance, `expose` only on consumer ones (the
# starter endpoint 403s a B2B token). Managed stage only, so the clean base stays clean.
COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37
RUN install -d -m 0755 /usr/local/lib/hermes/skills/agent37-cron
COPY --chmod=0644 shared/hermes-skills/agent37-cron/SKILL.md /usr/local/lib/hermes/skills/agent37-cron/SKILL.md

USER node
