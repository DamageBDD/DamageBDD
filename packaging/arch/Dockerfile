# syntax=docker/dockerfile:1.7

############################################
# Base toolchain (stable, cached layer)
############################################
FROM archlinux:latest AS base

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CCACHE_DIR=/ccache

WORKDIR /src

############################################
# Pacman setup (rarely changes)
############################################
RUN sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf \
 && pacman -Syy --noconfirm archlinux-keyring \
 && pacman-key --init \
 && pacman-key --populate archlinux

############################################
# Mirror selection (keep cached)
############################################
RUN pacman -S --noconfirm --needed reflector ca-certificates \
 && reflector \
      --country AU,NZ \
      --protocol https \
      --latest 20 \
      --sort rate \
      --save /etc/pacman.d/mirrorlist

############################################
# System update
############################################
RUN pacman -Syu --noconfirm

############################################
# Build dependencies (this layer changes often)
############################################
RUN pacman -S --noconfirm --needed \
    base-devel git fakeroot which curl wget \
    tar gzip unzip xz zstd patch pkgconf \
    cmake ninja make gcc \
    erlang rebar3 jq pacman-contrib \
    libsodium kubo pass cuda vim gtk4 \
    ccache \
 && mkdir -p "$CCACHE_DIR" /root/.cache \
 && pacman -Scc --noconfirm
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
FROM fetch AS runtime
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN pacman -Syu --noconfirm
#
WORKDIR /app
COPY --from=fetch /src /app

# Default to a shell so you can explore artifacts or run your binary/script.

# Create non-root user and group for running Damage/Build tools
RUN groupadd -r damage && \
    useradd -r -g damage -d /home/damage -m -s /bin/bash damage
RUN mkdir /out
RUN chown -R damage:damage /app /out
USER damage

CMD ["bash"]

