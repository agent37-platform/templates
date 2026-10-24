# syntax=docker/dockerfile:1
# Agents API v1 (B2B) base sandbox: the agent37-base system template, and the default for a
# create that names no template. A plain Linux box for running code: Node, Python, git and a
# build toolchain, plus a terminal in the browser. No agent, no chat gateway, no managed model,
# no desktop or browser, so it boots fast and idles at a few MB. Customers who want an agent
# pick an agent template; customers who want more tools build FROM this image.
#
# One port: the ttyd terminal on 7681. No file manager on 8080, because 8080 is the first port
# a customer's own web app reaches for. SSH (22022) is injected by the platform.
#
# Build context is the repo root. Tag comes from images.json; publish via
# scripts/publish-image.sh b2b-base.
#
# node:24-bookworm, the same base as every other B2B image: it already carries git, curl and
# gcc/make, so the list below is only what it lacks.
FROM node:24-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive

# EXTERNALLY-MANAGED is removed so a plain `pip install` works: as node it lands in ~/.local,
# on the durable home, which is what a sandbox user expects of pip.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-dev python-is-python3 \
    jq ripgrep rsync zip unzip xz-utils file \
    vim nano less \
    procps lsof iproute2 \
    tini \
  && rm -rf /var/lib/apt/lists/* \
  && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED \
  # Debian ships the node account locked ('!'), and sshd refuses locked accounts even for
  # pubkey auth; customer SSH lands as node. '*' = no password login, not locked.
  && usermod -p '*' node

ARG UV_VERSION=0.13.5
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh \
  && uv --version

ARG TTYD_VERSION=1.7.7
ARG TARGETARCH
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "${arch}" in \
       amd64|x86_64) ttyd_arch="x86_64" ;; \
       arm64|aarch64) ttyd_arch="aarch64" ;; \
       *) echo "Unsupported arch: ${arch}" >&2; exit 1 ;; \
     esac \
  && curl -fsSL -o /usr/local/bin/ttyd \
       "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
  && chmod 0755 /usr/local/bin/ttyd \
  && ttyd --version

COPY --chmod=0755 images/b2b/base/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/home/node
ENV NPM_CONFIG_PREFIX=${HOME}/.npm-global
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PATH=${HOME}/.local/bin:${NPM_CONFIG_PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR ${HOME}

EXPOSE 7681

USER node

# tini as PID 1 reaps whatever exec'd commands leave behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
