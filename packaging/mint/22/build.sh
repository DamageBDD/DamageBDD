#DOCKER_BUILDKIT=1 docker build --pull \
#  --build-arg APT_BUSTER=$(date +%s) \
#  --build-arg REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3 \
#  -t damagebdd/rebar3-mint:latest .
set -e

DOCKER_BUILDKIT=1 docker build \
  --build-arg CACHEBUST=$(date +%s) \
  -t damagebdd/mint22-builder:latest .
#rm -f deb/*.deb
docker run --rm -it \
  -v "$(pwd)/deb:/out" \
  -w /opt/workspace \
  damagebdd/mint22-builder:latest \
  bash -lc '
    set -e
    git reset --hard
    # optional, only if this is actually a git clone:
    if [ -d .git ]; then git pull --ff-only --tags || true; fi

    rm -f rebar.lock
    rm -rf _build

    DEBUG=1
    rebar3 as prod release

    # package with your plugin
    rebar3 pkg gen -t deb

    # copy debs to host
    rm -f /out/*.deb
    cp -a _build/pkg/deb/*.deb /out/
    rm -f rebar.lock

  '
