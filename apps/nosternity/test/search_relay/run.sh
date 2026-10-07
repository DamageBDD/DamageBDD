#!/usr/bin/env bash
# Run against real project dependencies and native ECAI. Build the project first,
# or supply ERL_LIBS pointing at application directories (jsx, ecai, etc.).
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/nosternity-search-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ebin"
paths=()
for path in "$root"/_build/default/lib/*/ebin; do
    [[ -d "$path" ]] && paths+=( -pa "$path" )
done
erlc "${paths[@]}" -DTEST -I apps/ecai/include -o "$work/ebin" \
    apps/nosternity/src/nostrlib_schnorr.erl \
    apps/damage/src/damage_nostr_event.erl \
    apps/nosternity/src/nosternity_config.erl \
    apps/nosternity/src/nosternity_app.erl \
    apps/nosternity/src/nosternity_sup.erl \
    apps/nosternity/src/nosternity_filter.erl \
    apps/nosternity/src/nosternity_relay.erl \
    apps/nosternity/src/nosternity_event_store.erl \
    apps/nosternity/src/nosternity_websocket.erl \
    apps/nosternity/src/nosternity_search_http.erl \
    apps/nosternity/src/nosternity_llm_bridge.erl \
    apps/damage/src/damage_gun.erl apps/damage/src/damage_otp_compat.erl \
    apps/ecai/src/ecai_ollama_client.erl \
    apps/ecai/src/ecai_search.erl apps/ecai/src/ecai_terms.erl \
    apps/ecai/src/ecai_tokenizer.erl apps/ecai/src/ecai_utils.erl \
    apps/ecai/src/ecai_private_policy.erl apps/ecai/src/ecai_chunker.erl \
    apps/ecai/src/ecai_index_job_codec.erl \
    apps/nosternity/test/nosternity_config_tests.erl \
    apps/nosternity/test/nosternity_startup_tests.erl \
    apps/nosternity/test/nosternity_search_tests.erl \
    apps/nosternity/test/nosternity_search_http_tests.erl \
    apps/nosternity/test/nosternity_llm_bridge_tests.erl \
    apps/nosternity/test/nosternity_test_llm_http.erl \
    apps/nosternity/test/nosternity_search_integration_tests.erl
erl "${paths[@]}" -pa "$work/ebin" -noshell -eval '
    case eunit:test([nosternity_config_tests, nosternity_startup_tests,
        nosternity_search_tests, nosternity_search_http_tests,
        nosternity_llm_bridge_tests, nosternity_search_integration_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
