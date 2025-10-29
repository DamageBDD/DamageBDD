#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-arch-build:latest}"
WORKDIR="${2:-$(pwd)}"

# Run container as your host UID:GID so build artifacts aren't owned by root.
# HOME is set to /workspace so tools that write to $HOME behave sanely.
docker run --rm -it \
       --hostname archbuild \
       --user $(id -u):$(id -g) \
       -e HOME=/workspace \
       -v "$WORKDIR":/workspace \
       -w /workspace \
       "$IMAGE_NAME" bash
