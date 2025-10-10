#DOCKER_BUILDKIT=1 docker build --pull \
#  --build-arg APT_BUSTER=$(date +%s) \
#  --build-arg REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3 \
#  -t damagebdd/rebar3-mint:latest .
DOCKER_BUILDKIT=1 docker build -t damagebdd/mint22-builder:latest .
docker run --rm -it \
  -w /opt/workspace \
  damagebdd/mint22-builder:latest \
  bash -lc '
    set -e
    git pull origin develop
    rm rebar.lock -f
    rm -rf _build
    rebar3 as prod release
    rebar3 pkg gen -t deb
  '

