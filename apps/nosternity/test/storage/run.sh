#!/usr/bin/env bash
# Real filesystem and DETS tests; no native ECAI index is needed.
# Run without root DAC override privileges so chmod restrictions produce EACCES.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/storage-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ebin"
erlc -Werror -I apps/damage/include -o "$work/ebin" \
    apps/damage/src/damage_config.erl \
    apps/nosternity/src/nosternity_config.erl \
    apps/nosternity/src/nosternity_branding.erl \
    apps/nosternity/test/nosternity_branding_tests.erl \
    apps/nosternity/src/nosternity_storage.erl \
    apps/nosternity/src/nosternity_filter.erl \
    apps/nosternity/src/nosternity_auth.erl \
    apps/nosternity/src/nosternity_relay.erl \
    apps/nosternity/test/nosternity_storage_tests.erl
erl -pa "$work/ebin" -noshell -eval '
    case eunit:test([nosternity_storage_tests, nosternity_branding_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
