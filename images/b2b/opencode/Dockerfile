# syntax=docker/dockerfile:1
# Agents API v1 (B2B) OpenCode runtime. One multi-stage build; the publish script pushes two
# targets:
#   base -> ghcr.io/agent37-platform/opencode-base  Clean OpenCode + the Agent37 gateway
#           (opencode adapter) on 3737, terminal, file browser. No managed integrations and no
#           managed model. The FROM target for customer custom OpenCode templates.
#   full -> ghcr.io/agent37-platform/opencode       The agent37-opencode system template:
#           base + the managed Agent37 model (out of the box, no login) and the managed Composio
#           MCP registration, both driven by the platform token at boot.
#
# Unlike Codex and Claude Code, OpenCode needs no account: the full image ships the managed
# Agent37 model (custom provider `agent37`, served by the platform LLM proxy) as the default, so
# a turn works the moment the instance is up. A customer can still bring their own provider key
# (OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY, ...) in instance env;
# OpenCode registers that provider natively and the model is then selectable per turn. The
# gateway never reads credentials — the managed key lives only in OpenCode's config file.
#
# Lean and headless: no browser, no desktop, no Playwright (customers who want one build FROM
# opencode-base and add it).
#
# Build context is docker/ so it shares shared/. Tag comes from docker/images.json; publish via
# scripts/publish-image.sh b2b-opencode (pushes base and full at one tag).
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

# Bake OpenCode from its GitHub release tarball (its install script hard-codes ~/.opencode/bin
# and sniffs the build-host CPU, so it is unusable in a Dockerfile). The tarball is a single
# `opencode` binary. It lives outside /home/node so the persisted volume cannot mask it: the
# gateway spawns exactly this binary (OPENCODE_BIN below), never a copy a user drops into the
# user-first PATH.
ARG TARGETARCH
ARG OPENCODE_VERSION=1.18.34
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "${arch}" in \
       amd64|x86_64) oc_arch="x64" ;; \
       arm64|aarch64) oc_arch="arm64" ;; \
       *) echo "Unsupported arch: ${arch}" >&2; exit 1 ;; \
     esac \
  && curl -fsSL -o /tmp/opencode.tar.gz \
       "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-${oc_arch}.tar.gz" \
  && tar -xzf /tmp/opencode.tar.gz -C /tmp \
  && install -m 0755 /tmp/opencode /usr/local/bin/opencode \
  && rm -f /tmp/opencode.tar.gz /tmp/opencode \
  && test -x /usr/local/bin/opencode \
  && /usr/local/bin/opencode --version

# Bake the Agent37 gateway (the per-instance chat adapter) from its release tag. It lives
# outside /home/node so the persisted volume cannot mask it; its state (sqlite, logs) goes to
# ~/.agent37-gateway on the volume at runtime. --omit=optional skips the Claude Agent SDK's
# platform packages (unused by the opencode adapter, which drives a resident `opencode serve`
# over HTTP via OPENCODE_BIN). The tag must be >= v0.12.0 (the opencode adapter).
ARG GATEWAY_VERSION=v0.14.0
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

COPY --chmod=0755 images/b2b/opencode/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/node
ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global
ENV PYTHONUSERBASE=${HOME}/.local
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV HOMEBREW_ALLOW_EUID=1
ENV GATEWAY_WORKSPACE_DIR=${HOME}
ENV GATEWAY_DEFAULT_AGENT=opencode
ENV OPENCODE_BIN=/usr/local/bin/opencode

ENV PATH=${HOME}/.venv/bin:${PYTHONUSERBASE}/bin:${NPM_CONFIG_PREFIX}/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR ${HOME}

EXPOSE 3737 7681 8080

USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Managed layer: the boot-time OpenCode config updater (the managed `agent37` model, the Composio
# MCP registration, and the Composio usage guidance). Runtime starter credentials activate them;
# the clean base does not bake the script and the entrypoint skips the step.
FROM base AS full

USER root

ENV AGENT37_MANAGED_INTEGRATIONS=1

RUN install -d -m 0755 /usr/local/lib/agent37
COPY --chmod=0755 shared/configure-opencode-config.sh /usr/local/lib/agent37/configure-opencode-config.sh

# The agent37 CLI: `cron` works on every instance, `expose` only on consumer ones (the
# starter endpoint 403s a B2B token). Managed stage only, so the clean base stays clean.
COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37

USER node
