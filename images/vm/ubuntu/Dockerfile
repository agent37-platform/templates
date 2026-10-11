# syntax=docker/dockerfile:1
# Agents API v1 (B2B) Ubuntu runtime, for `type: 'vm'` instances only: it needs a real
# kernel, so it cannot run as a gVisor sandbox. Backs the public agent37-ubuntu system
# template. Docker, Compose and buildx are installed and dockerd IS the entrypoint,
# so the customer SSHes in (or execs) and runs their own containers, compose stacks, k3s or
# emulator on a machine that behaves like any other Ubuntu box.
#
# Bump = a new Ubuntu base or package set: bump the tag in images.json, publish via
# scripts/publish-image.sh vm-ubuntu.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
# Deliberately nothing the platform already provides: sshd, the guest kernel and its module
# tree are mounted in read-only, so the image installs none of them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        docker.io docker-compose-v2 docker-buildx \
        ca-certificates curl git kmod iproute2 less sudo tini \
    && rm -rf /var/lib/apt/lists/*

# The instance's one durable disk is mounted at the image's home directory, so HOME is also
# this image's declaration of what survives an image bump.
ENV HOME=/root
WORKDIR /root
COPY --chmod=0755 images/vm/ubuntu/entrypoint.sh /usr/local/bin/agent37-entrypoint.sh

ENTRYPOINT ["tini", "--", "/usr/local/bin/agent37-entrypoint.sh"]
