#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
JSX_EBIN=${JSX_EBIN:-"$REPO/_build/default/lib/jsx/ebin"}
cp "$REPO/apps/erm/test/share_isolated/ecai_private_index.erl.fixture" "$BUILD/ecai_private_index.erl"
erlc -Werror -o "$BUILD" "$BUILD/ecai_private_index.erl" \
  "$REPO/apps/ecai/src/ecai_share.erl" \
  "$REPO/apps/erm/src/erm_share_files.erl" \
  "$REPO/apps/erm/src/erm_share.erl" \
  "$REPO/apps/erm/src/erm_share_ui.erl" \
  "$REPO/apps/erm/src/erm_optional_services.erl" \
  "$REPO/apps/erm/test/share_isolated/erm_share_tests.erl"
# Existing gtkgs fake backend verifies the real UI object/event contract.
erlc -o "$BUILD" "$REPO/apps/erm/src/gtknode4_backend.erl"
erlc -pa "$BUILD" -I "$REPO/apps/erm/src" -o "$BUILD" \
  "$REPO/apps/erm/src/erm_log.erl" "$REPO/apps/erm/src/gtknode4.erl" \
  "$REPO/apps/erm/src/gtknode4_fake.erl" "$REPO/apps/erm/src/gtknode4_sup.erl" \
  "$REPO/apps/erm/src/gtkgs.erl"
erl -noshell -pa "$BUILD" "$JSX_EBIN" -eval \
  'case eunit:test(erm_share_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'
python3 "$REPO/apps/erm/test/share_isolated/test_omdrop_hook.py"
