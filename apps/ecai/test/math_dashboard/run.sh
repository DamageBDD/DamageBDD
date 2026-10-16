#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
command -v erlc >/dev/null || { echo 'Erlang/OTP 27+ (erlc) is required.' >&2; exit 127; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-math-dashboard-test.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
erl +S 2:2 +A 1 -noshell -eval 'true = list_to_integer(erlang:system_info(otp_release)) >= 27, halt().'
# Fake auth/Cowboy/trails adapters are ONLY placed on this temporary test path.
for fixture in "$ROOT"/apps/ecai/test/math_dashboard/fixtures/*.erl.fixture \
               "$ROOT"/apps/ecai/test/math_dashboard/ecai_math_dashboard_http_tests.erl.fixture; do
  cp -- "$fixture" "$OUT/$(basename -- "${fixture%.fixture}")"
done
erlc -Werror -o "$OUT" "$OUT"/damage_auth.erl "$OUT"/cowboy_req.erl "$OUT"/trails.erl
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT"/apps/ecai/src/ecai_math_*.erl
# Compile the edited dashboard renderer too; no dependent application is started.
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT/apps/ecai/src/ecai_dashboard.erl"
erlc -Werror -pa "$OUT" -o "$OUT" "$ROOT"/apps/ecai/test/math_dashboard/ecai_math_dashboard_tests.erl "$OUT/ecai_math_dashboard_http_tests.erl"
erl +S 2:2 +A 1 -noshell -pa "$OUT" -eval '
  application:ensure_all_started(crypto),
  case eunit:test([ecai_math_dashboard_tests,ecai_math_dashboard_http_tests],[verbose]) of
    ok -> halt(0); _ -> halt(1)
  end.'
