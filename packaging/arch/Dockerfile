# syntax=docker/dockerfile:1.7

############################################
# DamageBDD Arch Linux release builder
############################################
FROM archlinux:latest AS base

ARG LIBOQS_VERSION=0.16.0

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CCACHE_DIR=/ccache \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64

WORKDIR /src

############################################
# Pacman bootstrap
#
# Arch is rolling. Never refresh repository metadata and then install
# packages without first bringing the base image fully up to date.
############################################
RUN set -eux; \
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf; \
    pacman-key --init; \
    pacman-key --populate archlinux; \
    pacman -Sy --noconfirm --needed archlinux-keyring; \
    pacman -Syu --noconfirm; \
    pacman -S --noconfirm --needed reflector ca-certificates; \
    reflector \
      --country AU,NZ \
      --protocol https \
      --latest 20 \
      --sort rate \
      --save /etc/pacman.d/mirrorlist; \
    pacman -Syyu --noconfirm

############################################
# Build dependencies
############################################
RUN set -eux; \
    install_deps() { \
      pacman -S --noconfirm --needed \
        base-devel \
        git fakeroot which curl wget util-linux \
        tar gzip unzip xz zstd patch pkgconf \
        cmake ninja make gcc \
        erlang rebar3 jq pacman-contrib \
        libsodium kubo pass cuda vim \
        gtk4 libshumate libxcb libx11 openssl \
        ccache; \
    }; \
    if ! install_deps; then \
      pacman -Syyu --noconfirm; \
      install_deps; \
    fi; \
    pkg-config --print-errors --exists \
      gtk4 shumate-1.0 xcb xcb-dpms xcb-screensaver x11; \
    command -v cmake >/dev/null; \
    command -v ninja >/dev/null; \
    command -v ccache >/dev/null; \
    mkdir -p "$CCACHE_DIR"; \
    pacman -Scc --noconfirm

############################################
# liboqs for DamageBDD PQC NIF
############################################
RUN set -eux; \
    test -n "$LIBOQS_VERSION"; \
    git clone --depth 1 --branch "$LIBOQS_VERSION" \
      https://github.com/open-quantum-safe/liboqs.git /tmp/liboqs; \
    cmake -S /tmp/liboqs -B /tmp/liboqs/build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_INSTALL_PREFIX=/usr/local; \
    cmake --build /tmp/liboqs/build --parallel "$(nproc)"; \
    cmake --install /tmp/liboqs/build; \
    rm -rf /tmp/liboqs; \
    pkg-config --print-errors --exists liboqs; \
    pkg-config --modversion liboqs

############################################
# Fetch source
############################################
FROM base AS fetch

ARG REPO_URL=https://github.com/DamageBDD/DamageBDD.git
ARG REPO_REF=develop

WORKDIR /opt

RUN set -eux; \
    test -n "$REPO_URL"; \
    test -n "$REPO_REF"; \
    git clone \
      --depth 1 \
      --single-branch \
      --branch "$REPO_REF" \
      "$REPO_URL" /opt/workspace; \
    test -d /opt/workspace/.git; \
    git -C /opt/workspace rev-parse --is-inside-work-tree

WORKDIR /opt/workspace

############################################
# Builder/runtime stage used by DamageBDD
############################################
FROM fetch AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/damage \
    XDG_CACHE_HOME=/home/damage/.cache \
    CCACHE_DIR=/ccache \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64

WORKDIR /opt/workspace

# Run release builds unprivileged. Cache directories must be writable by the
# same user because whisper.cpp/ggml automatically enables ccache when found.
RUN set -eux; \
    groupadd -r damage; \
    useradd -r -g damage -d /home/damage -m -s /bin/bash damage; \
    mkdir -p /out /ccache /home/damage/.cache; \
    chown -R damage:damage \
      /opt/workspace \
      /out \
      /ccache \
      /home/damage

USER damage

# Validate the non-root build environment while constructing the image rather
# than discovering permission or native dependency failures during rebar3.
RUN set -eux; \
    test -d .git; \
    test "$(git rev-parse --is-inside-work-tree)" = true; \
    test -f rebar.lock; \
    touch "$CCACHE_DIR/.write-test"; \
    rm "$CCACHE_DIR/.write-test"; \
    ccache --set-config=cache_dir="$CCACHE_DIR"; \
    ccache --set-config=max_size=10G; \
    ccache -z; \
    pkg-config --print-errors --exists \
      gtk4 shumate-1.0 xcb xcb-dpms xcb-screensaver x11 liboqs; \
    test -f /usr/include/gtk-4.0/gtk/gtk.h; \
    test -f /usr/include/xcb/dpms.h; \
    test -f /usr/include/xcb/screensaver.h

CMD ["bash"]
