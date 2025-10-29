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
    && mkdir -p "$CCACHE_DIR"  /root/.cache      && pacman -Scc --noconfirm

WORKDIR /src

############################################
# Fetch sources (cacheable by commit)
############################################
FROM base AS fetch
ARG REPO_URL=https://github.com/DamageBDD/DamageBDD.git
ARG REPO_REF=develop   # or a tag/sha

# Do a shallow clone if the ref is a branch or tag; fall back to full + checkout for SHA
# Note: Changing REPO_REF invalidates cache for this layer.
RUN git clone --depth=1 --branch "$REPO_REF" "$REPO_URL" /src || ( git clone "$REPO_URL" /src && cd /src && git checkout "$REPO_REF" )

WORKDIR /src
# Record exact commit to make downstream layers cache-stable when source hasn't changed
RUN git rev-parse HEAD > /commit.sha

############################################
# Build stage (language/tool-agnostic heuristics)
############################################
FROM base AS build
ARG REPO_URL
ARG REPO_REF
COPY --from=fetch /src /src


############################################
# Runtime image (slim; contains built artifacts)
############################################
FROM archlinux:latest AS runtime
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN pacman -Syu --noconfirm      && pacman -S --noconfirm --needed ca-certificates bash      && pacman -Scc --noconfirm

WORKDIR /app
COPY --from=build /src /app

RUN pacman -S --noconfirm git
RUN pacman -S --noconfirm rebar3
RUN pacman -S --noconfirm make
RUN pacman -S --noconfirm gcc
RUN pacman -S --noconfirm libsodium
RUN pacman -S --noconfirm base-devel
RUN pacman -S --noconfirm kubo
RUN pacman -S --noconfirm pass
# Default to a shell so you can explore artifacts or run your binary/script.
CMD ["bash"]
