#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
cd "$REPO"
make -C apps/erm/c_src/voice_notes
erlc -Werror -o "$BUILD" apps/ecai/src/ecai_voice_dsp.erl apps/ecai/src/ecai_voice_features.erl \
  apps/ecai/src/ecai_voice_wav.erl apps/ecai/src/ecai_voice_curve.erl \
  apps/erm/src/erm_voice_notes*.erl apps/erm/test/voice_notes/erm_voice_notes_tests.erl apps/erm/test/voice_notes/erm_voice_notes_ui_tests.erl
erlc -o "$BUILD" apps/erm/src/gtknode4_backend.erl
erlc -pa "$BUILD" -I apps/erm/src -o "$BUILD" apps/erm/src/erm_log.erl apps/erm/src/gtknode4.erl \
  apps/erm/src/gtknode4_fake.erl apps/erm/src/gtknode4_sup.erl apps/erm/src/gtkgs.erl
ERL_FLAGS="${ERL_FLAGS:-} +S 4:4" erl -noshell -pa "$BUILD" -eval \
  'case eunit:test([erm_voice_notes_tests,erm_voice_notes_ui_tests],[verbose]) of ok->halt(0);_->halt(1) end.'
ECAI_NOTES_TEST_EBIN="$BUILD" python3 apps/erm/test/voice_notes/test_native.py
