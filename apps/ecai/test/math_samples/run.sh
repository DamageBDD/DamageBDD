#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
node --test "$ROOT/apps/ecai/test/math_samples/samples.test.mjs" \
  "$ROOT/apps/ecai/test/math_dashboard/view_model.test.mjs"
python3 "$ROOT/apps/ecai/test/math_samples/test_samples.py"
command -v erlc >/dev/null || { echo 'JavaScript and Python fixture tests passed, but native sample replay is NOT run: Erlang/OTP 27+ is required.' >&2; exit 127; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-math-samples.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
export ECAI_MATH_SAMPLES_DIR="$ROOT/apps/ecai/priv/static/math-samples"
erl +S 2:2 +A 1 -noshell -eval 'true = list_to_integer(erlang:system_info(otp_release)) >= 27, halt().'
erlc -Werror -o "$OUT" "$ROOT"/apps/ecai/src/ecai_math_*.erl
# No live application, account, relay or funded node is started.
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT/apps/ecai/test/math_samples/ecai_math_samples_tests.erl"
erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
    case eunit:test(ecai_math_samples_tests,[verbose]) of
        ok -> halt(0); _ -> halt(1)
    end.'
