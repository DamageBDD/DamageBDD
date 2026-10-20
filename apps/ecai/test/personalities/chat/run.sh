#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-personality-chat.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
command -v erlc >/dev/null || { echo 'Erlang/OTP required; chat tests were NOT run.' >&2; exit 127; }
JSX_EBIN=${JSX_EBIN:-"$ROOT/_build/default/lib/jsx/ebin"}
[[ -f "$JSX_EBIN/jsx.beam" ]] || { echo 'Set JSX_EBIN to the compiled jsx ebin directory.' >&2; exit 1; }
# These modules deliberately replace production names. Stage them outside test/
# so rebar3 cannot recursively compile them into the normal EUnit code path.
mkdir -p "$OUT/src"
for fixture in "$ROOT/apps/ecai/test/personalities/chat/"*.erl.fixture; do
    cp -- "$fixture" "$OUT/src/$(basename -- "${fixture%.fixture}")"
done
erlc -Werror -o "$OUT" "$ROOT/apps/ecai/src/ecai_chat.erl" \
    "$ROOT/apps/ecai/src/ecai_otp_compat.erl" \
    "$OUT/src/"*.erl
erl +S 2:2 +A 1 -noshell -pa "$JSX_EBIN" "$OUT" -eval '
    case eunit:test(ecai_chat_personality_tests,[verbose]) of
        ok -> halt(0); _ -> halt(1)
    end.'
