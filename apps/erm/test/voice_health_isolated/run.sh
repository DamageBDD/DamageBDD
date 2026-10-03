#!/bin/sh
# Never install diagnostic Logger fixtures into an existing application VM.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export VOICE_LOG_TEST_TMP="$tmp"
export VOICE_LOG_TEST_CONFIG="${1:-$here/logger.config}"
cp "$here/erm_voice_health_tests.erl.fixture" "$tmp/erm_voice_health_tests.erl"
erlc -Werror -o "$tmp" "$root/apps/erm/src/erm_voice_health.erl" "$tmp/erm_voice_health_tests.erl"
erl -noshell -pa "$tmp" -eval '
case eunit:test(erm_voice_health_tests, [verbose]) of
    ok -> halt(0);
    _ -> halt(1)
end.'
