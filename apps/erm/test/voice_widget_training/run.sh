#!/bin/sh
set -eu
widget_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
cd "$widget_root"
widget_tmp=$(mktemp -d)
trap 'rm -rf "$widget_tmp"' EXIT HUP INT TERM
export PHRASE_TEST_TMP="$widget_tmp" PHRASE_TEST_ERM="$widget_root/apps/erm"
export PHRASE_TEST_PEER="$widget_tmp/fake_port"
export PHRASE_TEST_LAB="$widget_tmp/phrase_lab" PHRASE_TEST_PLAYER="$widget_tmp/player"
command -v xdotool >/dev/null
make -C apps/erm/c_src/gtknode4
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror apps/erm/test/phrase_lab_isolated/fake_port.cpp -o "$PHRASE_TEST_PEER"
${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -pthread apps/erm/c_src/erm_phrase_lab_port.cpp -o "$PHRASE_TEST_LAB"
${CC:-cc} -O2 -Wall -Wextra -Werror apps/erm/test/phrase_lab_isolated/fake_player.c -o "$PHRASE_TEST_PLAYER"
for source in apps/erm/test/phrase_voice_isolated/*.erl.src apps/erm/test/phrase_lab_isolated/erm_phrase_lab_tests.erl.src; do
    cp "$source" "$widget_tmp/$(basename "$source" .src)"
done
erlc -o "$widget_tmp" apps/erm/src/erm_native_voice.erl
erlc -Werror -o "$widget_tmp" apps/erm/src/gtknode4_backend.erl
erlc -Werror -pa "$widget_tmp" -o "$widget_tmp" \
    apps/erm/src/gtkgs.erl apps/erm/src/gtkgs_motion.erl apps/erm/src/gtknode4.erl \
    apps/erm/src/gtknode4_port.erl apps/erm/src/gtknode4_sup.erl \
    apps/erm/src/erm_display.erl apps/erm/src/erm_log.erl apps/erm/src/erm_otp_compat.erl \
    apps/erm/src/erm_voice_events.erl apps/erm/src/erm_voice_widget.erl \
    apps/erm/src/erm_voice_training.erl apps/erm/src/erm_voice_diagnostics.erl apps/erm/src/erm_voice_profiles.erl apps/erm/src/erm_phrase_codec.erl \
    apps/erm/src/erm_phrase_voice.erl apps/erm/src/erm_phrase_lab.erl \
    apps/erm/src/erm_phrase_lab_native.erl apps/erm/src/erm_phrase_lab_store.erl \
    apps/erm/src/erm_phrase_lab_metrics.erl "$widget_tmp"/*.erl \
    apps/erm/test/voice_widget_training/erm_voice_widget_training_tests.erl
if [ "${MOTION_USE_DISPLAY:-0}" = 1 ]; then
    set -- env
else
    set -- xvfb-run -a -s '-screen 0 1800x1000x24' env
fi
"$@" GSK_RENDERER=cairo G_DEBUG=fatal-criticals \
    erl +S 2 -sname "widget_test_$$@localhost" -setcookie widget_test -noshell -pa "$widget_tmp" \
    -eval 'application:ensure_all_started(crypto), case eunit:test(erm_voice_widget_training_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
