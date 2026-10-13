
# Append to the existing, reviewed Arch/Manjaro builder Dockerfile.
# This is a Dockerfile fragment, not a standalone image definition.
# Install inside the image as root; feature execution remains unprivileged.
USER root
RUN pacman -Syu --noconfirm --needed pkgconf gtk4 libshumate \
    && pkg-config --print-errors --exists gtk4 shumate-1.0 \
    && pkg-config --cflags gtk4 shumate-1.0 >/dev/null \
    && pkg-config --libs gtk4 shumate-1.0 >/dev/null
USER damage
WORKDIR /opt/workspace
