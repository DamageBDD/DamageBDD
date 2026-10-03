#!/bin/sh
set -eu
tts_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
tts_tests="$tts_root/apps/erm/test/tts_discovery_isolated"
: "${PIPER_INCLUDE:?Set PIPER_INCLUDE to directory containing official piper.h}"
tts_tmp=$(mktemp -d)
trap 'rm -rf "$tts_tmp"' EXIT HUP INT TERM
export ERM_TTS_TEST_DIR="$tts_tmp"
export ERM_TTS_PLAYER_HOLD="$tts_tmp/player.hold"
export ERM_TTS_PLAYER_HEARTBEAT="$tts_tmp/player.heartbeat"
export ERM_TTS_CAPTURE_WAV="$tts_tmp/output.wav"
export ERM_TTS_CAPTURE_ARGS="$tts_tmp/player.args"
export ERM_TTS_CAPTURE_TEXT="$tts_tmp/spoken.txt"
export ERM_TTS_PLAYER_PID="$tts_tmp/player.pid"
mkdir -p "$tts_tmp/erm-0.0/ebin" "$tts_tmp/erm-0.0/priv" "$tts_tmp/bin" "$tts_tmp/sdk/share/espeak-ng-data"
touch "$tts_tmp/model" "$tts_tmp/config" "$tts_tmp/model.json" "$tts_tmp/phontab" "$tts_tmp/sdk/share/espeak-ng-data/phontab"
c++ -std=c++17 -pthread -Wall -Wextra -I"$PIPER_INCLUDE" \
 "$tts_root/apps/erm/c_src/erm_tts_port.cpp" "$tts_tests/fake_piper.cpp" -o "$tts_tmp/port"
c++ -std=c++17 "$tts_tests/fake_player.cpp" -o "$tts_tmp/player"
cp "$tts_tmp/port" "$tts_tmp/erm-0.0/priv/erm_tts_port"
cp "$tts_tmp/player" "$tts_tmp/bin/mpv"
PATH="$tts_tmp/bin:$PATH"
export PATH
printf '{application,erm,[{vsn,"0.0"},{modules,[]}]} .\n' > "$tts_tmp/erm-0.0/ebin/erm.app"
for f in "$tts_root"/apps/erm/test/support/voice/*.erl.src "$tts_tests"/*.erl.src; do
 cp "$f" "$tts_tmp/$(basename "$f" .src)"
done
erlc -o "$tts_tmp/erm-0.0/ebin" "$tts_root/apps/erm/src/erm_tts.erl" \
 "$tts_root/apps/erm/src/erm_tts_paths.erl" "$tts_root"/apps/erm/src/erm_model_*.erl \
 "$tts_root/apps/erm/src/erm_voice.erl" "$tts_root/apps/erm/src/erm_voice_tts.erl" \
 "$tts_root/apps/erm/src/erm_voice_boundary.erl" "$tts_root/apps/erm/src/erm_voice_intent.erl" "$tts_tmp"/*.erl
erl +S 2 -noshell -pa "$tts_tmp/erm-0.0/ebin" -eval \
 'persistent_term:put({erm_voice_test,http_scenario},voice), case eunit:test([erm_tts_chunk_tests,erm_tts_paths_tests,erm_tts_tests,erm_tts_controls_tests],[verbose]) of ok->halt(0);_->halt(1) end.'
