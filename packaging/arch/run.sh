#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-arch-build:latest}"

# Run container as your host UID:GID so build artifacts aren't owned by root.
# HOME is set to /workspace so tools that write to $HOME behave sanely.
CACHE_ROOT="${HOME}/.archcache"

unset http_proxy
unset https_proxy


docker run --rm -it \
       --hostname archbuild \
       --user $(id -u):$(id -g) \
       -e HOME=/opt/workspace \
       -v "$(pwd)/zst:/out" \
       -v "$(pwd)/DamageBDD:/opt/workspace" \
       -w /opt/workspace \
        -v "$CACHE_ROOT/ccache:/ccache" \
       "$IMAGE_NAME" \
       bash -lc '
    set -e
    set -x
    git reset --hard
    # optional, only if this is actually a git clone:
    if [ -d .git ]; then git pull --ff-only || true; fi

    rm -f rebar.lock
    rm -rf _build

    DEBUG=1 rebar3 as prod release

    # package with your plugin
    export CUDA_LIB64=/opt/cuda/lib64/
    DEBUG=1 rebar3 pkg gen -t arch
    cd _build/pkg/arch/damage/
    makepkg 

    # copy debs to host
    rm -f /out/*.zst
    cp -a *.zst /out/
    rm -f rebar.lock

  '
