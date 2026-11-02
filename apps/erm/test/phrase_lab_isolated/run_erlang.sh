#!/bin/sh
set -eu
command -v erlc >/dev/null 2>&1 || { echo 'Erlang tests NOT RUN: erlc is required.' >&2; exit 127; }
command -v erl >/dev/null 2>&1 || { echo 'Erlang tests NOT RUN: erl is required.' >&2; exit 127; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ERM=$(CDPATH= cd -- "$HERE/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export PHRASE_TEST_TMP="$TMP"
export PHRASE_TEST_ERM="$ERM"
export PHRASE_TEST_PEER="$TMP/fake_port"
export PHRASE_TEST_LAB="$TMP/lab_port" PHRASE_TEST_PLAYER="$TMP/fake_player"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror "$HERE/fake_port.cpp" -o "$PHRASE_TEST_PEER"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -pthread "$ERM/c_src/erm_phrase_lab_port.cpp" -o "$PHRASE_TEST_LAB"
${CC:-cc} -O2 -Wall -Wextra -Werror "$HERE/fake_player.c" -o "$PHRASE_TEST_PLAYER"
for source in "$ERM/test/phrase_voice_isolated"/*.erl.src "$HERE"/*.erl.src; do
    cp "$source" "$TMP/$(basename "$source" .src)"
done
# Production speaker math and all production lab modules. The tiny peer/models
# are external boundaries only, not replacements for recognition policy.
erlc -o "$TMP" "$ERM/src/erm_native_voice.erl"
erlc -Werror -o "$TMP" "$ERM/src/erm_voice_calibration.erl" "$ERM/src/erm_voice_boundary.erl" "$ERM/src/erm_voice_acoustics.erl" "$ERM/src/erm_voice_profiles.erl" "$ERM/src/erm_phrase_codec.erl" "$ERM/src/erm_phrase_voice.erl" \
    "$ERM/src/erm_voice_events.erl" "$ERM/src/erm_voice_training.erl" \
    "$ERM/src/erm_voice_diagnostics.erl" \
    "$ERM/src/erm_phrase_lab.erl" "$ERM/src/erm_phrase_lab_native.erl" \
    "$ERM/src/erm_phrase_lab_store.erl" "$ERM/src/erm_phrase_lab_metrics.erl" "$TMP"/*.erl
erl +S 2 -noshell -pa "$TMP" -eval \
 'application:ensure_all_started(crypto), case eunit:test([erm_voice_calibration_tests,erm_phrase_tests,erm_phrase_lab_tests,erm_voice_diagnostics_tests,erm_voice_debug_tests],[verbose]) of ok -> halt(0); _ -> halt(1) end.'

# A fresh VM proves routes/specs against the uploaded production modules, not
# the policy suite's fixture implementations of erm_voice/erm_voice_intent.
mkdir "$TMP/integration"
erlc -o "$TMP/integration" "$ERM/src/erm_voice.erl" \
    "$ERM/src/erm_voice_intent.erl" "$ERM/src/erm_voice_tts.erl" \
    "$ERM/src/erm_voice_boundary.erl" "$ERM/src/erm_model_pull.erl"
erlc +export_all -o "$TMP/integration" "$ERM/src/erm_sup.erl"
erlc -Werror -o "$TMP/integration" "$ERM/src/erm_voice_calibration.erl" "$ERM/src/erm_voice_boundary.erl" "$ERM/src/erm_voice_acoustics.erl" "$ERM/src/erm_voice_profiles.erl" "$ERM/src/erm_phrase_codec.erl" \
    "$TMP/erm_phrase_integration_tests.erl"
erl +S 2 -noshell -pa "$TMP/integration" -eval \
 'case eunit:test(erm_phrase_integration_tests,[verbose]) of ok -> halt(0); _ -> halt(1) end.'
