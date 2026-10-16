#!/usr/bin/env bash
set -euo pipefail
MODE=${1:-test}
case "$MODE" in test|--demo) ;; *) echo "Usage: $0 [--demo]" >&2; exit 2;; esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--demo]" >&2; exit 2; }
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
command -v erlc >/dev/null || { echo 'Erlang/OTP 27+ compiler (erlc) is required.' >&2; exit 127; }
command -v erl >/dev/null || { echo 'Erlang runtime (erl) is required.' >&2; exit 127; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-math-test.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
erl +S 2:2 +A 1 -noshell -eval '
  case list_to_integer(erlang:system_info(otp_release)) >= 27 of
    true -> halt(0); false -> io:format("OTP 27+ required (JSON codec).~n"), halt(1)
  end.'
erlc -Werror -o "$OUT" "$ROOT"/apps/ecai/src/ecai_math_*.erl \
  "$ROOT/apps/damage/src/steps_ecai_math.erl"
# The relation bridge has no NIF dependency. Include the existing relation
# source when running inside the full repository; it is not replaced here.
if [[ -f "$ROOT/apps/ecai/src/ecai_relation.erl" ]]; then
  erlc -o "$OUT" "$ROOT/apps/ecai/src/ecai_relation.erl"
fi
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT/apps/ecai/test/math_pathfinder/ecai_math_tests.erl"
erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
  application:ensure_all_started(crypto),
  case eunit:test(ecai_math_tests,[verbose]) of
    ok -> halt(0); _ -> halt(1)
  end.'

if [[ "$MODE" == --demo ]]; then
  erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
    application:ensure_all_started(crypto),
    {ok,Path} = ecai_math_pathfinder:demo(),
    io:format("Demo summary: ~p~n",[maps:with([hops,total_cost,total_degree,id],Path)]),
    {ok,Receipt} = ecai_math_pathfinder:verify_path(Path),
    io:format("Replayed verification: ~p~n",[maps:with([status,scope,formal_proof],Receipt)]),
    halt(0).'
fi
