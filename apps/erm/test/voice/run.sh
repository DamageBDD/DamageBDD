#!/bin/sh
# Run only in a fresh VM: fixture modules deliberately replace external APIs.
set -eu
voice_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
voice_tmp=$(mktemp -d)
trap 'rm -rf "$voice_tmp"' EXIT HUP INT TERM
mkdir -p "$voice_tmp/ebin" "$voice_tmp/fixtures" "$voice_tmp/src" "$voice_tmp/media" "$voice_tmp/cache"
export ERM_VOICE_TEST_DIR="$voice_tmp/media"
export XDG_CACHE_HOME="$voice_tmp/cache"
erlc -DTEST -I "$voice_root/apps/erm/include" -o "$voice_tmp/ebin" \
  "$voice_root"/apps/erm/src/erm_voice*.erl \
  "$voice_root/apps/erm/src/whisper_trigger_srv.erl" \
  "$voice_root/apps/erm/src/whisper_trigger_ui.erl" \
  "$voice_root/apps/erm/src/erm_sup.erl" \
  "$voice_root/apps/erm/test/erm_voice_tests.erl"
# EUnit also discovers erm_voice_tests when testing erm_voice; list it once.
erl +S 2 -noshell -pa "$voice_tmp/ebin" -eval \
  'case eunit:test([erm_voice, erm_voice_boundary, whisper_trigger_srv], [verbose]) of ok -> halt(0); _ -> halt(1) end.'
for f in "$voice_root"/apps/erm/test/support/voice/*.erl.src \
         "$voice_root"/apps/erm/test/voice/fixtures/*.erl.src; do
  cp "$f" "$voice_tmp/src/$(basename "$f" .src)"
done
erlc -I "$voice_root/apps/erm/include" -o "$voice_tmp/fixtures" "$voice_tmp"/src/*.erl
erl +S 2 -noshell -pa "$voice_tmp/ebin" -pa "$voice_tmp/fixtures" \
  -eval 'persistent_term:put({erm_voice_test,http_scenario},voice), ok=voice_smoke:run(), halt(0).'
