#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
for f in "$root"/apps/erm/test/support/voice/*.erl.src \
         "$root"/apps/erm/test/ollama_pull/fixtures/*.erl.src; do
    cp "$f" "$tmp/$(basename "$f" .src)"
done
erlc -o "$tmp" "$root/apps/erm/src/erm_voice.erl" "$root/apps/erm/src/erm_voice_intent.erl" "$root/apps/erm/src/erm_voice_boundary.erl" "$root/apps/erm/src/erm_voice_tts.erl" "$tmp"/*.erl
erl +S 2 -noshell -pa "$tmp" -eval 'persistent_term:put({erm_voice_test,http_scenario},pull), case eunit:test(pull_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
