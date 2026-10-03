#!/bin/sh
# Run in a separate VM: the fixture replaces the production coordinator.
set -eu
native_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
native_tests="$native_root/apps/erm/test/native_voice_isolated"
NATIVE_TEST_TMP=$(mktemp -d)
export NATIVE_TEST_TMP
trap 'rm -rf "$NATIVE_TEST_TMP"' EXIT HUP INT TERM
cc -Wall -Wextra -Werror "$native_tests/fake_port.c" -o "$NATIVE_TEST_TMP/fake_port"
for f in "$native_tests"/*.erl.src; do cp "$f" "$NATIVE_TEST_TMP/$(basename "$f" .src)"; done
erlc -Werror -o "$NATIVE_TEST_TMP" "$native_root/apps/erm/src/erm_native_voice.erl" \
    "$native_root/apps/erm/src/erm_voice_boundary.erl" "$NATIVE_TEST_TMP"/*.erl
erlc +export_all -o "$NATIVE_TEST_TMP" "$native_root/apps/erm/src/erm_sup.erl"
erl +S 2 -noshell -pa "$NATIVE_TEST_TMP" -eval 'case eunit:test(erm_native_voice_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
