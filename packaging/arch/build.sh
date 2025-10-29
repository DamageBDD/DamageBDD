#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-arch-build:latest}"

echo "Building image: $IMAGE_NAME"
DOCKER_BUILDKIT=1 docker build --pull -t "$IMAGE_NAME" -f Dockerfile .
echo "Done."
