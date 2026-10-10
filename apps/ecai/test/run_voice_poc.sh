#!/usr/bin/env bash
# Run from any directory. Compiles ONLY the new voice modules and their tests.
set -euo pipefail
APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd -- "$APP_DIR/../.." && pwd)"
MODE="${1:-all}"
case "$MODE" in all|test|demo|compile) ;; *) echo "Usage: $0 [all|test|demo|compile]" >&2; exit 2 ;; esac
for CMD in erlc erl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Missing $CMD: install Erlang/OTP compiler, crypto and EUnit, then rerun." >&2
        exit 127
    fi
done
BUILD="${ECAI_VOICE_BUILD_DIR:-$ROOT_DIR/_build/ecai_voice_poc}"
mkdir -p -- "$BUILD/ebin" "$BUILD/reports" "$BUILD/demo"
BUILD="$(cd -- "$BUILD" && pwd)"
export ECAI_VOICE_DEMO_DIR="$BUILD/demo"
export ERL_CRASH_DUMP="$BUILD/reports/erl_crash.dump"
EBIN="$BUILD/ebin"
erlc -Werror +debug_info -o "$EBIN" \
    "$APP_DIR"/src/ecai_voice*.erl "$APP_DIR"/test/ecai_voice*_tests.erl \
    2>&1 | tee "$BUILD/reports/compile.log"
# The ERM shell facade is tested for compile compatibility without starting ERM.
if [[ -f "$ROOT_DIR/apps/erm/src/erm_voice_loop.erl" ]]; then
    erlc -Werror +debug_info -o "$EBIN" "$ROOT_DIR/apps/erm/src/erm_voice_loop.erl" \
        2>&1 | tee -a "$BUILD/reports/compile.log"
fi
if [[ "$MODE" == compile ]]; then
    echo "Compiled voice modules: $EBIN"
    exit 0
fi
if [[ "$MODE" == all || "$MODE" == test ]]; then
    erl -noshell -noinput -pa "$EBIN" -eval '
        {ok, _} = application:ensure_all_started(crypto),
        io:format("OTP ~s~n", [erlang:system_info(otp_release)]),
        Result = eunit:test([ecai_voice_curve_tests, ecai_voice_wav_tests,
                            ecai_voice_features_tests, ecai_voice_tests,
                            ecai_voice_loop_tests, ecai_voice_live_tests,
                            ecai_voice_session_tests, ecai_voice_tts_tests,
                            ecai_voice_diagnostics_tests], [verbose]),
        case Result of ok -> halt(0); _ -> halt(1) end.' \
        2>&1 | tee "$BUILD/reports/eunit.log"
fi
if [[ "$MODE" == all || "$MODE" == demo ]]; then
    erl -noshell -noinput -pa "$EBIN" -eval '
        {ok, _} = application:ensure_all_started(crypto),
        case ecai_voice_demo:run(os:getenv("ECAI_VOICE_DEMO_DIR")) of
            {ok, R} ->
                io:format("~tp~n", [maps:with([kind, profile, calibration,
                    curve_integer_decisions_identical, otp_release], R)]),
                io:format("Curve counts: ~tp~n", [maps:get(counts, maps:get(curve, R))]),
                io:format("Integer counts: ~tp~n", [maps:get(counts, maps:get(integer, R))]),
                halt(0);
            {error, Reason} -> io:format(standard_error, "Demo failed: ~tp~n", [Reason]), halt(1)
        end.' 2>&1 | tee "$BUILD/reports/demo.log"
    # A separate VM tests safe profile decoding without an earlier feature extraction.
    erl -noshell -noinput -pa "$EBIN" -eval '
        {ok, _} = application:ensure_all_started(crypto),
        Path = filename:join(os:getenv("ECAI_VOICE_DEMO_DIR"), "voices.ecv"),
        case ecai_voice:load(Path) of
            {ok, P} -> ok = ecai_voice:validate(P), io:format("Fresh-VM profile reload: ok~n"), halt(0);
            E -> io:format(standard_error, "Fresh-VM reload failed: ~tp~n", [E]), halt(1)
        end.' 2>&1 | tee "$BUILD/reports/fresh-vm-reload.log"
fi
echo "Reports: $BUILD/reports"
