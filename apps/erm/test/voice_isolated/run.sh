#!/bin/sh
# Real modules + local test doubles in a separate VM. Never loads mocks into a node.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export VOICE_TEST_TMP="$tmp"
export XDG_CACHE_HOME="$tmp/cache"
for file in "$here"/*.erl.fixture; do
    cp "$file" "$tmp/$(basename "$file" .fixture)"
done
include=${ERM_INCLUDE:-"$root/apps/erm/include"}
erlc -Werror -I "$include" -o "$tmp" \
    "$root/apps/erm/src/erm_voice.erl" \
    "$root/apps/erm/src/erm_voice_boundary.erl" \
    "$root/apps/erm/src/erm_voice_intent.erl" \
    "$root/apps/erm/src/erm_voice_tts.erl" \
    "$root/apps/erm/src/erm_voice_media.erl" \
    "$root/apps/erm/test/erm_voice_tests.erl" "$tmp"/*.erl
erl -noshell -pa "$tmp" -eval '
case eunit:test([erm_voice_tests, erm_voice_integration_tests], [verbose]) of
    ok -> halt(0);
    _ -> halt(1)
end.'
