#DOCKER_BUILDKIT=1 docker build --pull \
#  --build-arg APT_BUSTER=$(date +%s) \
#  --build-arg REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3 \
#  -t damagebdd/rebar3-mint:latest .
DOCKER_BUILDKIT=1 docker build -t damagebdd/mint22-builder:latest .

docker run --rm -it \
  -v "$(pwd)/deb:/out" \
  -w /opt/workspace \
  damagebdd/mint22-builder:latest \
  bash -lc '
    set -e
    # optional, only if this is actually a git clone:
    if [ -d .git ]; then git pull --ff-only || true; fi

    rm -f rebar.lock
    rm -rf _build

    rebar3 as prod release

    # package with your plugin
    rebar3 pkg gen -t deb

    # copy debs to host
    cp -a _build/pkg/deb/*.deb /out/
  '
