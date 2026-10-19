#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 0 && ( $# != 2 || ${1:-} != --export ) ]]; then
  echo 'Usage: run.sh [--export /absolute/path/report.json]' >&2; exit 2
fi
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
command -v erlc >/dev/null || { echo 'Erlang/OTP 27+ compiler (erlc) is required.' >&2; exit 127; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-explorer-test.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
erl +S 2:2 +A 1 -noshell -eval 'true=list_to_integer(erlang:system_info(otp_release))>=27,halt().'
erlc -Werror -o "$OUT" "$ROOT"/apps/ecai/src/ecai_math_*.erl "$ROOT/apps/damage/src/steps_ecai_math_explorer.erl"
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT/apps/ecai/test/math_explorer/ecai_math_explorer_tests.erl"
erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
  application:ensure_all_started(crypto),
  case eunit:test(ecai_math_explorer_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
if [[ ${1:-} == --export ]]; then
  [[ $# == 2 ]] || { echo 'Usage: run.sh [--export /absolute/path/report.json]' >&2; exit 2; }
  export ECAI_EXPLORATION_OUTPUT=$2
  erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
    application:ensure_all_started(crypto),
    {ok,S}=ecai_math_curve:new(0,-1,0),
    {ok,R}=ecai_math_explorer:explore(S,#{max_depth=>2,timeout_ms=>20000}),
    {ok,B}=ecai_math_explorer:encode(R),
    ok=file:write_file(os:getenv("ECAI_EXPLORATION_OUTPUT"),B,[exclusive]),
    io:format("~p~n",[maps:get(summary,R)]),halt().'
fi
