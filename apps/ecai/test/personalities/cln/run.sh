#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-personality-cln.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
command -v erlc >/dev/null || { echo 'Erlang/OTP required; CLN tests were NOT run.' >&2; exit 127; }
# The CLN double and its driver must never enter the umbrella test code path.
mkdir -p "$OUT/src"
for fixture in "$ROOT/apps/ecai/test/personalities/cln/"*.erl.fixture; do
    cp -- "$fixture" "$OUT/src/$(basename -- "${fixture%.fixture}")"
done
erlc -Werror -o "$OUT" "$ROOT/apps/ecai/src/ecai_personality_cln.erl" \
    "$OUT/src/damage_cln.erl" \
    "$OUT/src/ecai_personality_cln_tests.erl"
erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
    case eunit:test(ecai_personality_cln_tests,[verbose]) of
        ok -> halt(0); _ -> halt(1)
    end.'
