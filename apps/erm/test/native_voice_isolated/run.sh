#!/bin/sh
# Run in a separate VM: the fixture replaces the production coordinator.
set -eu
native_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
native_tests="$native_root/apps/erm/test/native_voice_isolated"
NATIVE_TEST_TMP=$(mktemp -d)
export NATIVE_TEST_TMP
unset NATIVE_TEST_DIM NATIVE_TEST_PROTOCOL
trap 'rm -rf "$NATIVE_TEST_TMP"' EXIT HUP INT TERM
cc -Wall -Wextra -Werror "$native_tests/fake_port.c" -o "$NATIVE_TEST_TMP/fake_port"
c++ -std=c++17 -Wall -Wextra -Werror "$native_tests/audio_levels.cpp" -o "$NATIVE_TEST_TMP/audio_levels"
"$NATIVE_TEST_TMP/audio_levels"
# Compile the actual port against test SDK boundaries; no models or downloads.
cc -Wall -Wextra -Werror "$native_tests/fake_capture.c" -o "$NATIVE_TEST_TMP/fake_capture"
c++ -std=c++17 -pthread -Wall -Wextra -Werror -I"$native_tests/sdk" \
    "$native_root/apps/erm/c_src/erm_native_voice.cpp" -o "$NATIVE_TEST_TMP/native_worker"
for f in "$native_tests"/*.erl.src; do cp "$f" "$NATIVE_TEST_TMP/$(basename "$f" .src)"; done
erlc -Werror -o "$NATIVE_TEST_TMP" "$native_root/apps/erm/src/erm_native_voice.erl" \
    "$native_root/apps/erm/src/erm_voice_boundary.erl" \
    "$native_root/apps/erm/src/erm_voice_acoustics.erl" \
    "$native_root/apps/erm/src/erm_voice_tune.erl" "$NATIVE_TEST_TMP"/*.erl
erlc +export_all -o "$NATIVE_TEST_TMP" "$native_root/apps/erm/src/erm_sup.erl"
erl +S 2 -noshell -pa "$NATIVE_TEST_TMP" -eval 'case eunit:test(erm_native_voice_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
