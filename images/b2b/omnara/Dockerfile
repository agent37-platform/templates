# syntax=docker/dockerfile:1
# agent37-omnara: the default template of an Omnara (omnara.com) machine pool on Agent37, so a
# pool works with nothing but an API key. Ubuntu 24.04 as root, with the tools of Omnara's
# default machine environment (https://docs.omnara.com/machines/pools#default-machine-environment)
# on the versions Ubuntu 24.04 and each vendor's own repository ship. Omnara installs and starts
# its daemon over exec, so the image runs no agent of its own: just the terminal on 7681.
#
# Build context is the repo root. Tag comes from images.json; publish via
# scripts/publish-image.sh b2b-omnara.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# /bin/sh is bash, as on Omnara's own machines, so a command written in bash syntax runs under
# the default shell. The cluster PostgreSQL would create on install is left to the agent
# (`pg_createcluster 18 main --start`), as Omnara documents it.
RUN ln -sf bash /usr/bin/sh \
  && apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /etc/apt/keyrings/redis.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/redis.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends postgresql-common \
  && sed -i 's/^#\?create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf \
  && apt-get install -y --no-install-recommends \
    git gh wget zip unzip xz-utils jq ripgrep sudo file less vim nano \
    procps lsof iproute2 openssh-client tini \
    build-essential cmake ninja-build pkg-config \
    python3 python3-pip python3-venv python3-dev python-is-python3 \
    nodejs \
    postgresql-18 redis sqlite3 \
    poppler-utils qpdf \
  && rm -rf /var/lib/apt/lists/* \
  && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED \
  # GITHUB_TOKEN or GH_TOKEN in the environment authenticates git over HTTPS too, through gh.
  && git config --system credential.https://github.com.helper '!gh auth git-credential'

ARG GO_VERSION=1.27.3
ARG YQ_VERSION=v4.54.1
ARG UV_VERSION=0.13.6
ARG TTYD_VERSION=1.7.7
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz \
  && curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  && curl -fsSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
  && chmod 0755 /usr/local/bin/yq /usr/local/bin/ttyd \
  && curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_UNMANAGED_INSTALL=/usr/local/bin sh \
  && npm install -g pnpm yarn \
  && npm cache clean --force

ENV PATH=/root/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_ROOT_USER_ACTION=ignore

RUN pip install --no-cache-dir \
    numpy pandas matplotlib openpyxl python-docx python-pptx pypdf playwright \
  && playwright install --with-deps --only-shell chromium \
  && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 images/b2b/base/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HOME=/root
RUN mkdir -p /workspace
WORKDIR /workspace

EXPOSE 7681

# tini as PID 1 reaps whatever the daemon and the agents' commands leave behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
