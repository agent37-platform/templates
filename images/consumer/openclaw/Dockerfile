# syntax=docker/dockerfile:1
# Consumer OpenClaw runtime (ghcr.io/agent37-platform/app-openclaw): the b2b openclaw system
# image plus exactly the consumer-product bits — the agent37 expose CLI (also installed as
# exposed-port, the B2C registry CLI's argv surface), the environment plugin that gates its
# prompt text on that CLI, and the noVNC desktop (Piece 5a, port 6080, shared/app-desktop/,
# supervised by the wrapper entrypoint — the b2b base is fully headless, so the wrapper owns
# the display; the managed browser itself runs headless, since the desktop is opened rarely
# enough that a visible browser only ever painted for nobody). Backs the
# internal agent37-app-openclaw template, created only by the B2C facade and the migration
# importer; B2B customer templates never see it.
#
# Build context is docker/ so it shares shared/. Tag comes from docker/images.json; publish via
# scripts/publish-image.sh consumer-openclaw. Bump OPENCLAW_BASE_TAG together with b2b-openclaw.
ARG OPENCLAW_BASE_TAG=2026.10.02b
FROM ghcr.io/agent37-platform/openclaw:${OPENCLAW_BASE_TAG}

USER root

# Full desktop stack: the b2b openclaw base ships no display packages at all (headless by
# design), so unlike consumer-app this adds the X server, WM, and browser together.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    chromium \
    openbox \
    x11-xserver-utils \
    tigervnc-standalone-server \
    novnc \
    websockify \
    idesk \
    feh \
    tint2 \
  && rm -rf /var/lib/apt/lists/*

# Same reason as the hermes base: installing chromium registers it as the system's link
# handler, so any `… login` CLI silently opens a browser window nobody closes. This image
# installs chromium itself, so it needs its own registration (the b2b openclaw base has none).
COPY --chmod=0755 shared/xdg/a37-show-url /usr/local/bin/a37-show-url
COPY --chmod=0644 shared/xdg/a37-show-url.desktop /usr/share/applications/a37-show-url.desktop
COPY --chmod=0644 shared/xdg/mimeapps.list /etc/xdg/mimeapps.list
RUN command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications || true

RUN install -d -m 0755 /usr/local/share/agent37-desktop /usr/local/lib/agent37
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
RUN ln -sf /usr/local/bin/agent37 /usr/local/bin/exposed-port \
  && node -e "require('fs').accessSync('/usr/local/bin/agent37')"
COPY --chmod=0644 shared/openclaw-plugins/agent37-environment/index.js /usr/local/lib/openclaw/plugins/agent37-environment/index.js

COPY --chmod=0755 images/consumer/openclaw/entrypoint.sh /usr/local/bin/app-entrypoint.sh

EXPOSE 6080

USER node

ENTRYPOINT ["/usr/local/bin/app-entrypoint.sh"]
