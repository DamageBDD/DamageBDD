#!/usr/bin/env bash
# Isolated real store/HTTP tests. Entitlement, generation and Cowboy are doubles;
# JSON encoding, DETS persistence, validation and handler dispatch are real.
# Do not compile the fixtures into a production application.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/ecai-conversation-personalities.XXXXXXXX")
trap 'rm -rf -- "$OUT"' EXIT
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
ECAI_ERL="${ECAI_ERL:-erl}"
ECAI_ERLC="${ECAI_ERLC:-erlc}"
CODE_PATH=(-pa "$OUT")
if [[ -n "${ECAI_JSX_EBIN:-}" ]]; then
    CODE_PATH+=(-pa "$ECAI_JSX_EBIN")
else
    for CANDIDATE in "$ROOT/_build/test/lib/jsx/ebin" \
                     "$ROOT/_build/default/lib/jsx/ebin" "$ROOT/deps/jsx/ebin"; do
        if [[ -f "$CANDIDATE/jsx.beam" ]]; then CODE_PATH+=(-pa "$CANDIDATE"); break; fi
    done
fi
"$ECAI_ERLC" -Werror -o "$OUT" \
    "$ROOT/apps/ecai/src/ecai_paths.erl" \
    "$ROOT/apps/ecai/src/ecai_otp_compat.erl" \
    "$ROOT/apps/ecai/src/ecai_tokenizer.erl" \
    "$ROOT/apps/ecai/src/ecai_terms.erl" \
    "$ROOT/apps/ecai/src/ecai_conversation_store.erl" \
    "$ROOT/apps/ecai/src/ecai_conversation_http.erl" \
    "$ROOT/apps/ecai/test/ecai_conversation_store_tests.erl" \
    "$ROOT/apps/ecai/test/conversation_personalities/fixtures/"*.erl \
    "$ROOT/apps/ecai/test/conversation_personalities/ecai_conversation_personalities_tests.erl"
"$ECAI_ERL" +S 2:2 +A 1 -noshell -noinput "${CODE_PATH[@]}" -eval '
    {ok, _} = application:ensure_all_started(crypto),
    {module, jsx} = code:ensure_loaded(jsx),
    case eunit:test([ecai_conversation_personalities_tests,
                     ecai_conversation_store_tests], [verbose]) of
        ok -> halt(0); _ -> halt(1)
    end.'
