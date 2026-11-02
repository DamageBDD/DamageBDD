#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
cd "$REPO"
ERL_ROOT=$(erl +S 2:2 -noshell -eval 'io:format("~s",[code:root_dir()]),halt().')
${CC:-cc} -O2 -Wall -Wextra -Wno-deprecated-declarations -pthread \
  $(pkg-config --cflags gtk4) -I"$ERL_ROOT/usr/include" \
  apps/erm/test/voice_notes/test_gtk_keys.c apps/erm/c_src/gtknode4/gtknode4_motion.c \
  $(pkg-config --libs gtk4 x11) -L"$ERL_ROOT/usr/lib" -lei -lm -o "$BUILD/test_gtk_keys"
if [ -n "${DISPLAY:-}" ]; then
  "$BUILD/test_gtk_keys"
else
  xvfb-run -a "$BUILD/test_gtk_keys"
fi
