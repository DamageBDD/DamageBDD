#!/bin/sh
# Verify the GTK4/Shumate toolchain before fetching/building Erlang dependencies.
# This is read-only except for a temporary compile/link probe; it installs nothing.
set -eu

fail() {
    printf '%s\n' "[damagebdd] native dependency check: $*" >&2
    exit 1
}

command -v pkg-config >/dev/null 2>&1 ||
    fail "pkg-config is missing. Install pkgconf in the builder image."

missing=0
for module in gtk4 shumate-1.0; do
    if ! pkg-config --print-errors --exists "$module"; then
        printf '%s\n' "[damagebdd] Missing pkg-config module: $module" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] ||
    fail "Install gtk4 and libshumate in the builder image, or correct PKG_CONFIG_PATH for an existing SDK."

# Capture separately: a failed command substitution inside a compiler command
# must not be mistaken for a compiler invocation with valid, empty flags.
cflags=$(pkg-config --cflags gtk4 shumate-1.0) ||
    fail "Cannot resolve GTK4/Shumate compiler flags."
libs=$(pkg-config --libs gtk4 shumate-1.0) ||
    fail "Cannot resolve GTK4/Shumate linker flags."

# CC must name one executable (no embedded command-line options).
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || fail "C compiler is missing: $cc"
probe=$(mktemp -d "${TMPDIR:-/tmp}/damage-gtk-check.XXXXXXXX") ||
    fail "Cannot create temporary probe directory."
trap 'rm -rf "$probe"' 0
trap 'exit 1' HUP INT TERM
cat > "$probe/check.c" <<'C'
#include <gtk/gtk.h>
#include <shumate/shumate.h>
int main(void) { return 0; }
C

# pkg-config returns compiler arguments. Split those arguments, but never glob
# them or eval them. Standard Arch/Manjaro package paths contain no whitespace.
set -f
# shellcheck disable=SC2086
"$cc" $cflags "$probe/check.c" -o "$probe/check" $libs ||
    fail "GTK4/Shumate header or link probe failed. Inspect the compiler error above."

# Do not run a GUI or start a display server in the build container.
printf '%s\n' '[damagebdd] GTK4/Shumate headers and linker inputs verified.'
pkg-config --modversion gtk4 shumate-1.0
