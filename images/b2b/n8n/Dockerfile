# syntax=docker/dockerfile:1
# Agents API v1 (B2B) n8n runtime: the official n8n image (n8nio/n8n on Docker Hub, a hardened
# Alpine with no package manager, no bash, no curl) as one Agent37 instance. Backs the public
# agent37-n8n system template: the editor, webhooks, and OAuth callbacks are served on 5678
# behind the instance's public port (n8n-{instanceId}.agent37.app), and n8n's own owner account
# guards the UI. Everything n8n persists (SQLite database, encryption key, settings) lives under
# /home/node/.n8n, on the instance's data volume.
#
# Bump = a new n8n release: change N8N_VERSION, bump the tag in docker/images.json, publish via
# scripts/publish-image.sh b2b-n8n.
ARG N8N_VERSION=2.41.6
# docker.io rather than the docker.n8n.io alias n8n documents: same registry and digest, but only
# the docker.io name carries the build machine's Docker Hub login (the alias pulls anonymously
# and gets rate-limited).
FROM docker.io/n8nio/n8n:${N8N_VERSION}

USER root
# sshd (customer SSH, bind-mounted by the host) refuses locked accounts even for pubkey auth;
# '*' = no password login, not locked.
RUN sed -i 's/^node:!/node:*/' /etc/shadow
COPY --chmod=0755 images/b2b/n8n/entrypoint.sh /usr/local/bin/agent37-entrypoint.sh
USER node

ENTRYPOINT ["tini", "--", "/usr/local/bin/agent37-entrypoint.sh"]
