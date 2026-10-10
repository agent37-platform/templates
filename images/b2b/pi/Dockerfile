# syntax=docker/dockerfile:1
# Agents API v1 (B2B) Pi runtime. One multi-stage build; the publish script pushes two
# targets:
#   base -> ghcr.io/agent37-platform/pi-base  Clean Pi + the Agent37 gateway (pi adapter)
#           on 3737, terminal, file browser. No managed model. The FROM target for customer
#           custom Pi templates.
#   full -> ghcr.io/agent37-platform/pi       The agent37-pi system template: base + the
#           managed Agent37 model (out of the box, no login), driven by the platform token
#           at boot.
#
# Pi (pi.dev) is a minimal agent harness: a four-tool core (read, bash, edit, write) that
# self-extends at runtime through TypeScript extensions, skills, prompt templates and themes.
# The full image ships the managed Agent37 model as pi's startup model, so a turn works the
# moment the instance is up; a customer can bring their own instead, either a provider key in
# instance env (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY, ... —
# pi reads them natively) or a Claude, ChatGPT or Copilot subscription via `/login` in the
# terminal. The gateway never reads credentials.
#
# Pi has no MCP client yet (upstream PR earendil-works/pi#10040), so this image ships no
# managed Composio registration: add the server here once that lands upstream.
#
# Lean and headless: no browser, no desktop, no Playwright (customers who want one build
# FROM pi-base and add it).
#
# Build context is docker/ so it shares shared/. Tag comes from docker/images.json; publish via
# scripts/publish-image.sh b2b-pi (pushes base and full at one tag).
#
# node:24: the baked agent37-gateway declares engines >=24, same as the other B2B images.
FROM node:24-bookworm AS base

USER root

ENV DEBIAN_FRONTEND=noninteractive

# Core toolbelt only (no browser/desktop stack). ffmpeg stays as a dormant CLI.
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
ARG UV_VERSION=0.12.22
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh \
  && command -v uv >/dev/null 2>&1 \
  && uv --version

# Bake Pi outside /home/node so the persisted volume cannot mask it. The gateway spawns
# exactly this binary (PI_BIN below), never a copy a user installs into the user-first PATH.
# --ignore-scripts is upstream's own recommended install: it skips dependency install scripts,
# and the published package declares none of its own.
ARG PI_VERSION=1.1.0
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g --no-audit --no-fund --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
  && npm cache clean --force \
  && rm -rf /home/node/.cache /home/node/.npm \
  && test -x /usr/local/bin/pi \
  && /usr/local/bin/pi --version

# Bake the Agent37 gateway (the per-instance chat adapter) from its release tag. It lives
# outside /home/node so the persisted volume cannot mask it; its state (sqlite, logs) goes to
# ~/.agent37-gateway on the volume at runtime. --omit=optional skips the Claude Agent SDK's
# platform packages (unused by the pi adapter, which spawns one `pi --mode json` process per
# turn via PI_BIN). The tag must be >= v0.16.0 (the pi adapter).
ARG GATEWAY_VERSION=v0.18.0
RUN git clone --depth 1 --branch "${GATEWAY_VERSION}" https://github.com/agent37-platform/gateway.git /usr/local/lib/agent37-gateway \
  && cd /usr/local/lib/agent37-gateway \
  && npm ci --no-audit --no-fund --omit=optional \
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

COPY --chmod=0755 images/b2b/pi/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/node
ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global
ENV PYTHONUSERBASE=${HOME}/.local
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV HOMEBREW_ALLOW_EUID=1
ENV GATEWAY_WORKSPACE_DIR=${HOME}
ENV GATEWAY_DEFAULT_AGENT=pi
ENV PI_BIN=/usr/local/bin/pi
# Pi's own config (models.json, settings.json, auth.json, skills) and one flat session store,
# both on the persisted volume. The session dir is set explicitly so the terminal and the API
# share one store: pi's default groups sessions per working directory instead.
ENV PI_CODING_AGENT_DIR=${HOME}/.pi/agent
ENV PI_CODING_AGENT_SESSION_DIR=${HOME}/.pi/sessions

ENV PATH=${HOME}/.venv/bin:${PYTHONUSERBASE}/bin:${NPM_CONFIG_PREFIX}/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR ${HOME}

EXPOSE 3737 7681 8080

USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Managed layer: the boot-time Pi config updater (the managed Agent37 model in pi's
# models.json, pi's startup model, and the managed guidance file). Runtime managed credentials
# activate it; the clean base does not bake the script and the entrypoint skips the step.
FROM base AS full

USER root

ENV AGENT37_MANAGED_MODEL=1

RUN install -d -m 0755 /usr/local/lib/agent37
COPY --chmod=0755 shared/configure-pi-config.sh /usr/local/lib/agent37/configure-pi-config.sh

# The agent37 CLI: `cron` works on every instance, `expose` only on consumer ones (the
# starter endpoint 403s a B2B token). Managed stage only, so the clean base stays clean.
COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37

USER node
