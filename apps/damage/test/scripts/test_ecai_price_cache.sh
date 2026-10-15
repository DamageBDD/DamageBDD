#!/usr/bin/env bash
# Offline EUnit suite; no Coinstore access or full application/dependency boot.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
for tool in erl erlc; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing %s: install Erlang/OTP with compiler, EUnit, crypto, public_key and inets.\n' "$tool" >&2
    exit 127
  }
done
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ecai-price-cache-eunit.XXXXXXXX")"
trap 'rm -rf -- "$OUT"' EXIT
SRC="$ROOT/apps/damage/src"
TEST="$ROOT/apps/damage/test"
MODULES=(ecai_mm_curve ecai_mm_config ecai_mm_ledger ecai_mm_candles
         ecai_mm_feed ecai_mm_price_cache ecai_mm_settings ecai_mm ecai_mm_http)
TESTS=(ecai_mm_curve_tests ecai_mm_config_tests ecai_mm_ledger_tests
       ecai_mm_candles_tests ecai_mm_feed_tests ecai_mm_price_cache_tests
       ecai_mm_settings_tests ecai_mm_tests)
FILES=()
for name in "${MODULES[@]}"; do FILES+=("$SRC/$name.erl"); done
for name in "${TESTS[@]}"; do FILES+=("$TEST/$name.erl"); done
erlc -DTEST -Werror -o "$OUT" "${FILES[@]}"
MODULE_LIST="$(IFS=,; echo "${TESTS[*]}")"
erl -noshell -pa "$OUT" -eval "
  {ok, _} = application:ensure_all_started(crypto),
  case eunit:test([$MODULE_LIST], [verbose]) of
    ok -> halt(0);
    _ -> halt(1)
  end."
