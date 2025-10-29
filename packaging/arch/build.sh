#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-arch-build:latest}"
REPO_URL_DEFAULT="${REPO_URL:-https://github.com/DamageBDD/DamageBDD.git}"
REPO_REF_DEFAULT="${REPO_REF:-develop}"

# Local directory for BuildKit cache (used by --cache-to/--cache-from)
CACHE_ROOT="${CACHE_ROOT:-$HOME/.archcache}"
BK_CACHE_DIR="${BK_CACHE_DIR:-$CACHE_ROOT/buildkit}"
mkdir -p "$BK_CACHE_DIR"

echo "==> Building image: $IMAGE_NAME"
echo "    REPO_URL=${REPO_URL_DEFAULT}"
echo "    REPO_REF=${REPO_REF_DEFAULT}"
echo "    BuildKit cache dir: $BK_CACHE_DIR"

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

docker build --pull \
       --build-arg "REPO_URL=${REPO_URL_DEFAULT}" \
       --build-arg "REPO_REF=${REPO_REF_DEFAULT}" \
       -t "$IMAGE_NAME" -f Dockerfile .
echo "==> Done."
