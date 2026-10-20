#!/usr/bin/env bash
# Run from the DamageBDD umbrella root after rebar3 compile.
# Optional RECORDS forces identical corpus size across all hardware profiles.
set -euo pipefail
PROFILE="${1:-smoke}"
OUT="${2:?usage: benchmark_index.sh PROFILE NEW_OUTPUT_DIRECTORY}"
case "$PROFILE" in
  smoke) CPU=1;; edge-2g|small-4g) CPU=2;; medium-8g) CPU=4;;
  large-16g) CPU=8;; xlarge-32g) CPU=16;; workstation-128g) CPU=32;;
  *) printf 'Unknown profile: %s\n' "$PROFILE" >&2; exit 2;;
esac
command -v erl >/dev/null || { echo "Erlang is required" >&2; exit 2; }
shopt -s nullglob
EBINS=(_build/default/lib/*/ebin)
((${#EBINS[@]})) || { echo "Run rebar3 compile from the umbrella root first" >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "Output path already exists; refusing to overwrite" >&2; exit 2; }
# -extra is data, never interpolated as Erlang source code.
exec erl +S "$CPU:$CPU" -noshell -pa "${EBINS[@]}" -eval '
  [Profile,Out,Count] = init:get_plain_arguments(),
  Opts = case Count of "" -> #{}; _ -> #{documents => list_to_integer(Count)} end,
  case ecai_index_benchmark:run(Profile,Out,Opts) of
    {ok,R} -> io:format("~ts~n",[jsx:encode(ecai_index_job_codec:externalize(R))]), halt(0);
    Error -> io:format(standard_error,"~p~n",[Error]), halt(1)
  end.' -extra "$PROFILE" "$OUT" "${RECORDS:-}"
