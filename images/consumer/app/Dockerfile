# syntax=docker/dockerfile:1
# Consumer app runtime (ghcr.io/agent37-platform/app): the b2b hermes system image plus
# everything the consumer product adds on top — the agent37 expose CLI, the agent37-expose
# skill (baked immutably; the config updater registers the directory in skills.external_dirs),
# the environment plugin rebuilt so its prompt self-gates on the agent37 CLI, Minions Mission
# Control (the consumer product's primary Hermes surface, port 6969, supervised by the wrapper
# entrypoint — the b2b image and its entrypoint stay untouched), the noVNC desktop (Piece 5a,
# port 6080, shared/app-desktop/), and the extra agent harnesses (Claude Code, Codex, OpenCode,
# and Grok today; more later). Harnesses beyond Hermes live HERE, never in the b2b hermes image: that image is the
# pure-Hermes contract B2B customers build on. Backs the internal agent37-app template,
# created only by the B2C facade and the migration importer; B2B customer templates never
# see it.
#
# Build context is docker/ so it shares shared/. Tag comes from docker/images.json; publish via
# scripts/publish-image.sh consumer-app. Bump HERMES_BASE_TAG together with b2b-hermes.
ARG HERMES_BASE_TAG=2026.09.27b
FROM ghcr.io/agent37-platform/hermes:${HERMES_BASE_TAG}

USER root

# Desktop stack (Piece 5a): Xtigervnc replaces the base image's Xvfb as the :99 server —
# purging xvfb removes /usr/bin/Xvfb, so the b2b entrypoint's display gate is false here,
# so the wrapper's supervise_app_desktop owns the display with no two-servers race.
# (openbox/chromium/x11-xserver-utils already ship in the hermes:full base.)
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    tigervnc-standalone-server \
    novnc \
    websockify \
    idesk \
    feh \
    tint2 \
  && apt-get purge -y xvfb \
  && rm -rf /var/lib/apt/lists/*

RUN install -d -m 0755 /usr/local/share/agent37-desktop
COPY --chmod=0644 shared/app-desktop/ideskrc \
  shared/app-desktop/browser.lnk \
  shared/app-desktop/wallpaper.jpg \
  shared/app-desktop/tint2rc \
  shared/app-desktop/novnc-agent37.css \
  /usr/local/share/agent37-desktop/
COPY --chmod=0644 shared/app-desktop/openbox-rc.xml /etc/xdg/openbox/rc.xml
COPY --chmod=0755 shared/app-desktop/app-desktop.sh /usr/local/lib/agent37/app-desktop.sh
RUN cat /usr/local/share/agent37-desktop/novnc-agent37.css >> /usr/share/novnc/app/styles/base.css

COPY --chmod=0755 shared/agent37-cli.js /usr/local/bin/agent37

RUN install -d -m 0755 /usr/local/lib/hermes/skills/agent37-expose
COPY --chmod=0644 shared/hermes-skills/agent37-expose/SKILL.md /usr/local/lib/hermes/skills/agent37-expose/SKILL.md
RUN install -d -m 0755 /usr/local/lib/hermes/skills/agent37-cron
COPY --chmod=0644 shared/hermes-skills/agent37-cron/SKILL.md /usr/local/lib/hermes/skills/agent37-cron/SKILL.md
COPY --chmod=0644 shared/configure-hermes-config.py /usr/local/lib/agent37/configure-hermes-config.py

COPY shared/hermes-plugins/agent37-environment/ /usr/local/lib/hermes/plugins/agent37-environment/
RUN uv pip install --python /usr/local/lib/hermes/hermes-agent/venv/bin/python \
    --reinstall-package agent37-hermes-environment /usr/local/lib/hermes/plugins/agent37-environment \
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

# Minions Mission Control for the consumer product (the CLI binary is `minions`). Installed
# under /usr/local: the base image's NPM_CONFIG_PREFIX points into /home/node, which the
# persisted home volume masks at runtime. 0.1.27+ is required on this Node 24 base: earlier
# releases pin better-sqlite3 11, which has no Node 24 prebuild and aborts at random GC.
ARG MINIONSAI_VERSION=0.1.27
RUN echo "Installing minionsai@${MINIONSAI_VERSION}" \
  && NPM_CONFIG_PREFIX=/usr/local npm install -g "minionsai@${MINIONSAI_VERSION}" \
  && test -x /usr/local/bin/minions \
  && npm cache clean --force \
  && rm -rf /home/node/.cache /home/node/.npm

# Bake Claude Code, the gateway's `claude-code` harness, outside /home/node so the persisted
# volume cannot mask it (same /usr/local prefix reasoning as minions above). The gateway
# spawns exactly this binary (CLAUDE_CODE_BIN below), never a copy a user installs into the
# user-first PATH. It runs on the user's own Claude login (`claude auth login` in the
# terminal); the image injects no credential for it.
ARG CLAUDE_CODE_VERSION=2.1.269
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
  && npm cache clean --force \
  && rm -rf /home/node/.cache /home/node/.npm \
  && test -x /usr/local/bin/claude \
  && /usr/local/bin/claude --version

# Admin-precedence Claude Code settings, outside the volume: keep transcripts (the gateway's
# session list) for years instead of the 30-day default sweep, and pin the version to the
# image (no self-updates, no background traffic). The directory is created explicitly:
# COPY --chmod would apply 0644 to a parent it creates, and node could not enter it.
RUN install -d -m 0755 /etc/claude-code
COPY --chmod=0644 shared/claude-managed-settings.json /etc/claude-code/managed-settings.json

# Boot-time Claude Code config (settings.json retention, the Composio MCP registration, and
# the CLAUDE.md guidance block). The b2b entrypoint runs it when present and skips it on the
# b2b images, which do not bake it.
COPY --chmod=0755 shared/configure-claude-config.sh /usr/local/lib/agent37/configure-claude-config.sh

ENV CLAUDE_CODE_BIN=/usr/local/bin/claude

# Bake Codex, the gateway's `codex` harness, outside /home/node (same /usr/local prefix
# reasoning as claude above). The gateway spawns exactly this binary (CODEX_BIN below). It runs
# on the user's own ChatGPT login (`codex login --device-auth` in the terminal); the image
# injects no credential for it. GATEWAY_DEFAULT_AGENT stays Hermes: Codex is one of the
# per-conversation harness options here, not the instance default.
ARG CODEX_VERSION=0.155.1
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g --no-audit --no-fund "@openai/codex@${CODEX_VERSION}" \
  && npm cache clean --force \
  && rm -rf /home/node/.cache /home/node/.npm \
  && test -x /usr/local/bin/codex \
  && /usr/local/bin/codex --version

# Boot-time Codex config (the headless approval/sandbox seed plus the Composio MCP block). The
# b2b hermes entrypoint (which this image's wrapper execs) runs it when present and skips it on
# the b2b images, which do not bake it.
COPY --chmod=0755 shared/configure-codex-config.sh /usr/local/lib/agent37/configure-codex-config.sh
COPY --chmod=0644 shared/codex-system-config.toml /usr/local/lib/agent37/codex-system-config.toml

ENV CODEX_BIN=/usr/local/bin/codex

# Bake OpenCode, the gateway's `opencode` harness, outside /home/node (same /usr/local prefix
# reasoning as claude/codex above). Installed from its GitHub release tarball, not npm: the
# install script hard-codes ~/.opencode/bin and sniffs the build-host CPU, so it is unusable in
# a Dockerfile. Needs no account — the managed Agent37 model works out of the box; the config
# updater below wires the managed model + Composio at boot. The gateway
# spawns exactly this binary (OPENCODE_BIN below). GATEWAY_DEFAULT_AGENT stays Hermes: OpenCode is
# one of the per-conversation harness options here, not the instance default.
ARG TARGETARCH
ARG OPENCODE_VERSION=1.18.32
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

# Boot-time OpenCode config (the managed Agent37 model + the Composio MCP block). The b2b hermes
# entrypoint (which this image's wrapper execs) runs it when present and skips it on the b2b
# images, which do not bake it.
COPY --chmod=0755 shared/configure-opencode-config.sh /usr/local/lib/agent37/configure-opencode-config.sh

ENV OPENCODE_BIN=/usr/local/bin/opencode

# Bake Grok Build, the gateway's `grok` harness, outside /home/node (same /usr/local prefix
# reasoning as claude/codex above). xAI ships prebuilt binaries from its CDN (the GitHub repo
# has no releases); the .gz asset gunzips to the self-contained Rust binary. It runs on the
# user's own xAI account (`grok login --device-code` in the terminal); the image injects no
# credential for it. GATEWAY_DEFAULT_AGENT stays Hermes: Grok is one of the per-conversation
# harness options here, not the instance default.
ARG GROK_VERSION=1.0.40
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "${arch}" in \
       amd64|x86_64) grok_arch="x86_64" ;; \
       arm64|aarch64) grok_arch="aarch64" ;; \
       *) echo "Unsupported arch: ${arch}" >&2; exit 1 ;; \
     esac \
  && curl -fsSL "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${GROK_VERSION}-linux-${grok_arch}.gz" \
    | gunzip > /usr/local/bin/grok \
  && chmod 0755 /usr/local/bin/grok \
  && /usr/local/bin/grok --version

# Boot-time Grok config (the Composio MCP block + the managed rules file). The b2b hermes
# entrypoint (which this image's wrapper execs) runs it when present and skips it on the b2b
# images, which do not bake it.
COPY --chmod=0755 shared/configure-grok-config.sh /usr/local/lib/agent37/configure-grok-config.sh

ENV GROK_BIN=/usr/local/bin/grok
# The baked binary is the only grok; its self-updater would install to ~/.grok/bin, which is
# not on PATH, and every boot would re-check. Off image-wide (terminal sessions included).
ENV GROK_DISABLE_AUTOUPDATER=1

COPY --chmod=0755 images/consumer/app/entrypoint.sh /usr/local/bin/app-entrypoint.sh

EXPOSE 6969 6080

USER node

ENTRYPOINT ["/usr/local/bin/app-entrypoint.sh"]
