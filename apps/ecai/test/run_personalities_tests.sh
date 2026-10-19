#!/usr/bin/env bash
# Run coordinator and NFT pure-unit tests without starting a node or moving funds.
# The parent DamageBDD checkout normally supplies jsx in _build/default/lib/jsx.
set -euo pipefail
APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd -- "$APP_DIR/../.." && pwd)"
ECAI_ERL="${ECAI_ERL:-erl}"
ECAI_ERLC="${ECAI_ERLC:-erlc}"
for CMD in "$ECAI_ERL" "$ECAI_ERLC"; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Missing $CMD: install Erlang/OTP, crypto and EUnit, then rerun." >&2
        exit 127
    fi
done
BUILD="${ECAI_PERSONALITIES_BUILD_DIR:-$ROOT_DIR/_build/ecai_personalities_tests}"
mkdir -p -- "$BUILD/ebin" "$BUILD/reports"
BUILD="$(cd -- "$BUILD" && pwd)"
export ERL_CRASH_DUMP="$BUILD/reports/erl_crash.dump"
CODE_PATH=(-pa "$BUILD/ebin")
if [[ -n "${ECAI_JSX_EBIN:-}" ]]; then
    CODE_PATH+=(-pa "$ECAI_JSX_EBIN")
else
    for CANDIDATE in "$ROOT_DIR/_build/test/lib/jsx/ebin" \
                     "$ROOT_DIR/_build/default/lib/jsx/ebin" \
                     "$ROOT_DIR/deps/jsx/ebin"; do
        if [[ -f "$CANDIDATE/jsx.beam" ]]; then
            CODE_PATH+=(-pa "$CANDIDATE")
            break
        fi
    done
fi
"$ECAI_ERLC" -Werror -DTEST +debug_info -o "$BUILD/ebin" \
    "$APP_DIR/src/ecai_paths.erl" \
    "$APP_DIR/src/ecai_personality_catalog.erl" \
    "$APP_DIR/src/ecai_personality_nft.erl" \
    "$APP_DIR/src/ecai_personalities.erl" \
    "$APP_DIR/test/ecai_personalities_test_backend.erl" \
    "$APP_DIR/test/ecai_personalities_tests.erl" \
    2>&1 | tee "$BUILD/reports/compile.log"
"$ECAI_ERL" -noshell -noinput "${CODE_PATH[@]}" -eval '
    {ok, _} = application:ensure_all_started(crypto),
    case code:ensure_loaded(jsx) of
        {module, jsx} -> ok;
        _ -> io:format(standard_error,
            "Missing jsx: build parent project dependencies or set ECAI_JSX_EBIN.~n", []), halt(2)
    end,
    io:format("OTP ~s; local fake remote services, no live payments or minting.~n",
              [erlang:system_info(otp_release)]),
    case eunit:test([ecai_personalities_tests, ecai_personality_nft], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.' 2>&1 | tee "$BUILD/reports/eunit.log"
echo "Reports: $BUILD/reports"
