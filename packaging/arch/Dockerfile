# syntax=docker/dockerfile:1
FROM archlinux:latest

# Minimal, reproducible Arch build environment
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Speed up pacman a bit; install common build tooling
RUN sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf \
    && pacman -Syu --noconfirm \
    && pacman -S --noconfirm --needed \
    base-devel git fakeroot which curl wget ca-certificates \
    tar gzip unzip xz zstd patch pkgconf cmake ninja \
    python python-pip go rust jq openssh pacman-contrib rebar3
RUN pacman -Syu --noconfirm erlang
RUN pacman -Syu --noconfirm libsodium
    #&& pacman -Scc --noconfirm

# Workspace will be bind-mounted from the host
WORKDIR /workspace

# Run an interactive shell by default
CMD ["bash"]
