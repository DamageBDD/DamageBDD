#!/bin/sh
# One invocation from the umbrella's post-compile hook. Build directly into
# the active profile; never teach the runtime loader to search source trees.
# Requires the shell-hook environment exported by Rebar3 >= 3.23.
set -eu
set -f

fail() { printf '%s\n' "OQS NIF build: $*" >&2; exit 1; }

case "${1:-compile}" in
    compile|clean) action=${1:-compile} ;;
    *) fail "usage: build_oqs_nif.sh [compile|clean]" ;;
esac
[ "$#" -le 1 ] || fail "too many arguments"

: "${REBAR_DEPS_DIR:?Rebar3 >= 3.23 must supply REBAR_DEPS_DIR to this hook}"
case "$REBAR_DEPS_DIR" in /*) ;; *) fail "REBAR_DEPS_DIR must be absolute" ;; esac
app_dir="$REBAR_DEPS_DIR/damage"
priv_dir="$app_dir/priv"
out="$priv_dir/secrets_pqc_oqs_nif.so"

if [ "$action" = clean ]; then
    # Only this generated artifact, including when priv is a Rebar symlink.
    rm -f -- "$out"
    exit 0
fi

: "${REBAR_ROOT_DIR:?Rebar3 must supply REBAR_ROOT_DIR}"
: "${ERLANG_ROOT_DIR:?Rebar3 must supply the active ERLANG_ROOT_DIR}"
: "${ERLANG_ERTS_VER:?Rebar3 must supply the active ERLANG_ERTS_VER}"
[ -d "$app_dir" ] || fail "active application directory is absent: $app_dir"
src="$REBAR_ROOT_DIR/apps/damage/c_src/secrets_pqc_oqs_nif.c"
[ -f "$src" ] || fail "source is absent: $src"

include="$ERLANG_ROOT_DIR/erts-$ERLANG_ERTS_VER/include"
if [ ! -f "$include/erl_nif.h" ]; then
    include="$ERLANG_ROOT_DIR/usr/include"
fi
[ -f "$include/erl_nif.h" ] || fail "active Erlang development headers are absent"

case "$(uname -s)" in
    Linux)  set -- -shared ;;
    Darwin) set -- -bundle -undefined dynamic_lookup ;;
    *) fail "only Linux and Darwin OQS builds are configured" ;;
esac

CC=${CC:-cc}
PKG_CONFIG=${PKG_CONFIG:-pkg-config}
# Tool/flag variables are trusted build inputs, word-split like normal CFLAGS.
# Deliberately no eval: shell metacharacters in these values are not executed.
$PKG_CONFIG --print-errors --exists liboqs || fail "liboqs.pc is unavailable"
oqs_cflags=$($PKG_CONFIG --cflags liboqs) || fail "cannot read liboqs compile flags"
oqs_libs=$($PKG_CONFIG --libs liboqs) || fail "cannot read liboqs link flags"

mkdir -p -- "$priv_dir"
umask 077
scratch=$(mktemp -d "$priv_dir/.oqs-build.XXXXXXXX") || fail "cannot allocate build directory"
cleanup() {
    rm -f -- "$scratch/secrets_pqc_oqs_nif.so"
    rmdir -- "$scratch" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

printf '===> Building OQS NIF for active profile: %s\n' "$out"
$CC ${CPPFLAGS:-} ${CFLAGS:--O2 -g} -std=c11 -fPIC -Wall -Wextra \
    -I"$include" $oqs_cflags "$src" "$@" \
    ${LDFLAGS:-} $oqs_libs ${LDLIBS:-} \
    -o "$scratch/secrets_pqc_oqs_nif.so"

[ -s "$scratch/secrets_pqc_oqs_nif.so" ] || fail "compiler did not produce a nonempty library"
chmod 755 "$scratch/secrets_pqc_oqs_nif.so"
# Install atomically; a failed build never leaves a truncated loadable target.
mv -f -- "$scratch/secrets_pqc_oqs_nif.so" "$out"
[ -s "$out" ] || fail "active-profile artifact is absent after installation"
