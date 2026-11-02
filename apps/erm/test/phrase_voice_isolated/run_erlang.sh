#!/bin/sh
set -eu
command -v erlc >/dev/null 2>&1 || { echo 'Erlang tests NOT RUN: erlc is required.' >&2; exit 127; }
command -v erl >/dev/null 2>&1 || { echo 'Erlang tests NOT RUN: erl is required.' >&2; exit 127; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ERM=$(CDPATH= cd -- "$HERE/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export PHRASE_TEST_TMP="$TMP"
export PHRASE_TEST_PEER="$TMP/fake_port"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror "$HERE/fake_port.cpp" -o "$PHRASE_TEST_PEER"
for source in "$HERE"/*.erl.src; do cp "$source" "$TMP/$(basename "$source" .src)"; done
# Production modules, not substitutes for the codec/gates/speaker math.
erlc -o "$TMP" "$ERM/src/erm_native_voice.erl"
erlc -Werror -o "$TMP" "$ERM/src/erm_voice_calibration.erl" "$ERM/src/erm_voice_profiles.erl" "$ERM/src/erm_phrase_codec.erl" "$ERM/src/erm_phrase_voice.erl" \
    "$ERM/src/erm_voice_events.erl" "$TMP"/*.erl
erl +S 2 -noshell -pa "$TMP" -eval \
    'application:ensure_all_started(crypto), case eunit:test(erm_phrase_tests,[verbose]) of ok -> halt(0); _ -> halt(1) end.'
