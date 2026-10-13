#!/usr/bin/env bash
# Focused tests against real Cowboy, JSX and bbmustache dependencies.
# Build the project first, or supply their application directories in ERL_LIBS.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/nosternity-branding-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nosternity/ebin"
cp apps/nosternity/src/nosternity.app.src "$work/nosternity/ebin/nosternity.app"
ln -s "$root/apps/nosternity/priv" "$work/nosternity/priv"
export ERL_LIBS="$work${ERL_LIBS:+:$ERL_LIBS}"
paths=()
for path in "$root"/_build/default/lib/*/ebin; do
    [[ -d "$path" ]] && paths+=( -pa "$path" )
done
erlc "${paths[@]}" -o "$work/nosternity/ebin" \
    apps/nosternity/src/nosternity_config.erl \
    apps/nosternity/src/nosternity_branding.erl \
    apps/nosternity/src/nosternity_page.erl \
    apps/nosternity/src/nosternity_dashboard.erl \
    apps/nosternity/src/nosternity_http.erl \
    apps/nosternity/src/nosternity_filter.erl \
    apps/nosternity/src/nosternity_websocket.erl \
    apps/nosternity/test/nosternity_branding_tests.erl \
    apps/nosternity/test/nosternity_branding_http_tests.erl \
    apps/nosternity/test/nosternity_dashboard_branding_tests.erl
erl "${paths[@]}" -pa "$work/nosternity/ebin" -noshell -eval '
    case eunit:test([nosternity_branding_tests,
        nosternity_branding_http_tests, nosternity_dashboard_branding_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
