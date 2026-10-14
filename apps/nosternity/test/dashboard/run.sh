#!/usr/bin/env bash
# Build the umbrella first. Uses its real dependencies (including native ECAI).
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/nosternity-dashboard-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nosternity/ebin"
cp apps/nosternity/src/nosternity.app.src "$work/nosternity/ebin/nosternity.app"
ln -s "$root/apps/nosternity/priv" "$work/nosternity/priv"
paths=()
for path in "$root"/_build/default/lib/*/ebin; do
    [[ -d "$path" ]] && paths+=( -pa "$path" )
done
# ERL_LIBS may also point at prebuilt real application dependencies.
erlc "${paths[@]}" -DTEST -I apps/damage/include -I apps/ecai/include -o "$work/nosternity/ebin" \
    apps/nosternity/src/nosternity_auth*.erl \
    apps/nosternity/src/nosternity_dashboard*.erl \
    apps/nosternity/src/nosternity_damage_http.erl \
    apps/nosternity/src/nosternity_config.erl \
    apps/nosternity/src/nosternity_storage.erl \
    apps/damage/src/damage_config.erl \
    apps/nosternity/src/nosternity_branding.erl \
    apps/nosternity/src/nosternity_page.erl apps/nosternity/src/nosternity_http.erl \
    apps/nosternity/src/nosternity_websocket.erl \
    apps/nosternity/src/nosternity_app.erl apps/nosternity/src/nosternity_sup.erl \
    apps/nosternity/src/nosternity_search_http.erl apps/nosternity/src/nosternity_filter.erl \
    apps/nosternity/src/nosternity_relay.erl apps/nosternity/src/nostrlib_schnorr.erl \
    apps/damage/src/damage_nostr_event.erl apps/damage/src/damage_browser_auth.erl \
    apps/damage/src/damage_browser_auth_http.erl apps/damage/src/damage_access_token.erl \
    apps/damage/src/damage_wallet_policy.erl apps/damage/src/damage_nwc_http.erl \
    apps/nosternity/test/nosternity_auth_tests.erl \
    apps/nosternity/test/nosternity_dashboard_http_tests.erl \
    apps/nosternity/test/nosternity_dashboard_branding_tests.erl \
    apps/damage/test/damage_browser_auth_origin_tests.erl
erl "${paths[@]}" -pa "$work/nosternity/ebin" -noshell -eval '
    case eunit:test([nosternity_auth_tests, nosternity_dashboard_http_tests,
        nosternity_dashboard_branding_tests,
        damage_browser_auth_origin_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
