#!/bin/sh
set -eu
loop_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
loop_tmp=$(mktemp -d)
trap 'rm -rf "$loop_tmp"' EXIT HUP INT TERM
cd "$loop_root"
loop_erl_root=${ERL_ROOT:-$(erl +S 2 -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')}
${CC:-cc} -std=c17 -O2 -Wall -Wextra -pthread \
    $(pkg-config --cflags gtk4) -I"$loop_erl_root/usr/include" \
    apps/erm/test/gtk_event_loop_isolated/loop_test.c \
    apps/erm/c_src/gtknode4/gtknode4_motion.c \
    $(pkg-config --libs gtk4 x11) -L"$loop_erl_root/usr/lib" -lei -lm \
    -o "$loop_tmp/loop_test"
for loop_case in main sync partial closed idle shutdown; do
    "$loop_tmp/loop_test" "$loop_case"
done
