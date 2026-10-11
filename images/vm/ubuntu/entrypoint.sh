#!/bin/sh
# dockerd in the foreground: when it dies the instance is dead, which is what makes a broken
# daemon show up as a crash loop instead of a quiet box nobody can use.
set -eu

# Docker's data MUST live on the durable disk. The instance's writable root is an overlayfs,
# and extracting an image layer onto one fails on the whiteout device nodes it has to create
# ("failed to convert whiteout file ...: operation not permitted"), so a data-root left at
# /var/lib/docker cannot even complete a pull. $HOME is the durable disk's mount point, and
# it is the same reason Agent37's own hosts keep dockerd's data-root off an overlay.
DATA="${AGENT37_DOCKER_DATA:-$HOME/docker}"
mkdir -p "$DATA" /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  printf '{\n  "data-root": "%s"\n}\n' "$DATA" > /etc/docker/daemon.json
fi

exec dockerd
