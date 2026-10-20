#!/bin/sh
set -eu
motion_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
MOTION_TEST_TMP=$(mktemp -d)
export MOTION_TEST_TMP
trap 'rm -rf "$MOTION_TEST_TMP"' EXIT HUP INT TERM
cd "$motion_root"
make -C apps/erm/c_src/gtknode4
erlc -Werror -o "$MOTION_TEST_TMP" apps/erm/src/gtknode4_backend.erl
erlc -Werror -pa "$MOTION_TEST_TMP" -o "$MOTION_TEST_TMP" \
    apps/erm/src/gtkgs.erl apps/erm/src/gtkgs_motion.erl apps/erm/src/gtknode4.erl \
    apps/erm/src/gtknode4_port.erl apps/erm/src/gtknode4_sup.erl \
    apps/erm/src/erm_display.erl apps/erm/src/erm_log.erl apps/erm/src/erm_otp_compat.erl \
    apps/erm/src/erm_voice_events.erl apps/erm/src/erm_voice_widget.erl \
    apps/ecai/src/ecai_voice_ui.erl apps/erm/test/gtkgs_motion_tests.erl
if [ "${MOTION_USE_DISPLAY:-0}" = 1 ]; then
    set -- env
else
    set -- xvfb-run -a env
fi
"$@" GSK_RENDERER=cairo G_DEBUG=fatal-criticals \
    erl +S 2 -sname "motion_test_$$@localhost" -setcookie motion_test -noshell -pa "$MOTION_TEST_TMP" \
    -eval 'case eunit:test(gtkgs_motion_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
