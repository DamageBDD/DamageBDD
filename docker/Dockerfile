# syntax=docker/dockerfile:1.7-labs
#
# DamageBDD Dockerfile
#
# Build style:
#   - Builder: official Erlang image with rebar3
#   - Runtime: slim Debian with only runtime libraries
#   - Source: local Docker build context, not git clone inside Dockerfile
#   - Security: non-root runtime user
#   - Speed: BuildKit cache mounts for apt and rebar3
#
# Build:
#   DOCKER_BUILDKIT=1 docker build -t damagebdd:local .
#
# Override versions:
#   docker build \
#     --build-arg ERLANG_VERSION=28 \
#     --build-arg DEBIAN_VERSION=bookworm \
#     --build-arg REBAR_PROFILE=prod \
#     --build-arg RELEASE_NAME=damage \
#     -t damagebdd:local .

ARG ERLANG_VERSION=28
ARG DEBIAN_VERSION=bookworm
ARG REBAR_PROFILE=prod
ARG RELEASE_NAME=damage

# -----------------------------------------------------------------------------
# Builder
# -----------------------------------------------------------------------------
FROM erlang:${ERLANG_VERSION}-${DEBIAN_VERSION} AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG REBAR_PROFILE
ARG RELEASE_NAME

WORKDIR /build

# Build dependencies only.
#
# Keep this lean:
#   - build-essential/autoconf/m4/pkg-config for native deps/NIFs
#   - libssl-dev/libsodium-dev/unixodbc-dev for crypto/network/db-linked Erlang deps
#   - git/ca-certificates/curl for rebar/git deps
#
# Removed from old image:
#   - kerl: official image already ships Erlang/OTP
#   - CUDA/GTK/ruby/fpm/rpm packaging: not needed to run DamageBDD
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential \
      autoconf \
      automake \
      m4 \
      pkg-config \
      git \
      ca-certificates \
      curl \
      openssl \
      libssl-dev \
      libsodium-dev \
      unixodbc-dev \
      xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Copy the whole local repo.
#
# Use .dockerignore to keep _build, .git, logs, data, secrets, and node volumes
# out of the Docker build context.
COPY . .

# Build release.
#
# Cache locations:
#   - /root/.cache/rebar3: package/git dependency cache
#   - /build/_build: build artifacts across rebuilds
#
# The release is expected at:
#   /build/_build/${REBAR_PROFILE}/rel/${RELEASE_NAME}
RUN --mount=type=cache,target=/root/.cache/rebar3 \
    --mount=type=cache,target=/build/_build \
    set -eux; \
    rebar3 as "${REBAR_PROFILE}" release; \
    test -x "_build/${REBAR_PROFILE}/rel/${RELEASE_NAME}/bin/${RELEASE_NAME}"

# Copy the release out of the cached build dir into a stable layer.
RUN set -eux; \
    mkdir -p /release; \
    cp -a "_build/${REBAR_PROFILE}/rel/${RELEASE_NAME}/." /release/

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG RELEASE_NAME

LABEL org.opencontainers.image.title="DamageBDD"
LABEL org.opencontainers.image.description="DamageBDD behaviour verification node"
LABEL org.opencontainers.image.vendor="DamageBDD"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV RELEASE_NAME="${RELEASE_NAME}" \
    HOME="/home/damage" \
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    DAMAGE_DATA_DIR="/var/lib/damage" \
    DAMAGE_RUN_DIR="/var/lib/damage/runs" \
    DAMAGE_REPORT_DIR="/var/lib/damage/reports" \
    DAMAGE_LOG_DIR="/var/log/damage" \
    DAMAGE_HTTP_PORT="4888" \
    PORT="4888"

# Runtime dependencies only.
#
# Notes:
#   - libssl3/libsodium23 are needed by crypto-linked deps/NIFs.
#   - unixodbc/libodbc2 are kept because the old builder included unixodbc-dev.
#   - wget/curl are included for simple Compose/Kubernetes healthchecks.
#   - tini gives sane PID 1 signal handling.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      openssl \
      libssl3 \
      libsodium23 \
      libstdc++6 \
      libgcc-s1 \
      libncurses6 \
      libtinfo6 \
      unixodbc \
      libodbc2 \
      zlib1g \
      curl \
      wget \
      tini; \
    rm -rf /var/lib/apt/lists/*

# Non-root operator user.
RUN set -eux; \
    groupadd --system damage; \
    useradd --system \
      --gid damage \
      --home-dir /home/damage \
      --create-home \
      --shell /usr/sbin/nologin \
      damage; \
    mkdir -p \
      /opt/damage \
      /var/lib/damage/runs \
      /var/lib/damage/reports \
      /var/log/damage; \
    chown -R damage:damage \
      /opt/damage \
      /var/lib/damage \
      /var/log/damage \
      /home/damage

WORKDIR /opt/damage

# Bring in only the built release from the builder stage.
COPY --from=builder --chown=damage:damage /release/ /opt/damage/

# Optional operator mount points.
#
# Compose can mount these:
#   ./features  -> /opt/damage/features:ro
#   ./contracts -> /opt/damage/contracts:ro
#   secrets     -> /run/secrets/damage:ro
VOLUME ["/var/lib/damage", "/var/log/damage"]

USER damage

EXPOSE 4888

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/version/" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/opt/damage/bin/damage", "foreground"]
