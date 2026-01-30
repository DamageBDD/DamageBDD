# syntax=docker/dockerfile:1.7

############################################
# Base toolchain (stable, cached layer)
############################################
FROM archlinux:latest AS base
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8    CCACHE_DIR=/ccache

# Prime pacman and install build deps in one layer
RUN sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf      \
    && pacman -Syu --noconfirm                                  \
    && pacman -S --noconfirm --needed                           \
    base-devel git fakeroot which curl wget ca-certificates     \
    tar gzip unzip xz zstd patch pkgconf cmake ninja            \
    erlang jq pacman-contrib ccache git rebar3 make             \
    gcc libsodium base-devel kubo pass cuda vim gtk4      \
    && mkdir -p "$CCACHE_DIR"  /root/.cache      && pacman -Scc --noconfirm

WORKDIR /src

############################################
# Fetch sources (cacheable by commit)
############################################
FROM base AS fetch
ARG REPO_URL=https://github.com/DamageBDD/DamageBDD.git
ARG REPO_REF=develop   # or a tag/sha

# Do a shallow clone if the ref is a branch or tag; fall back to full + checkout for SHA
RUN git clone --depth 1 "${REPO_URL}" /src \
    && cd /src \
    && git fetch --depth 1 origin "${REPO_REF}" || true \
    && git checkout "${REPO_REF}"

############################################
# Build image (compiles / artifacts)
############################################
#FROM fetch AS build

# Example: rebar3 compile / release
WORKDIR /src
#RUN rebar3 compile

#############################################
# Runtime image (slim; contains built artifacts)
#############################################
#FROM archlinux:latest AS runtime
#ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
#RUN pacman -Syu --noconfirm      && pacman -S --noconfirm --needed ca-certificates bash      && pacman -Scc --noconfirm
#
#WORKDIR /app
#COPY --from=build /src /app

# Default to a shell so you can explore artifacts or run your binary/script.

# Create non-root user and group for running Damage/Build tools
RUN groupadd -r damage && \
    useradd -r -g damage -d /home/damage -m -s /bin/bash damage

USER damage
WORKDIR /home/damage

CMD ["bash"]

