#!/bin/sh
# Fixtures exercise production algorithms/ports; no real model or audio device.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ERM=$(CDPATH= cd -- "$HERE/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CXX=${CXX:-c++}
CC=${CC:-cc}
FLAGS='-std=c++17 -O2 -Wall -Wextra -Werror'
"$CXX" $FLAGS -I"$ERM/c_src" "$ERM/test/phrase_voice_isolated/features_test.cpp" -o "$TMP/features"
"$CXX" $FLAGS -I"$ERM/c_src" "$HERE/synth_test.cpp" -o "$TMP/synth"
"$CXX" $FLAGS -pthread -I"$HERE/sdk" "$ERM/c_src/erm_native_voice.cpp" -o "$TMP/native"
"$CXX" $FLAGS -pthread "$ERM/c_src/erm_phrase_lab_port.cpp" -o "$TMP/lab"
"$CC" -O2 -Wall -Wextra -Werror "$HERE/fake_capture.c" -lm -o "$TMP/capture"
"$CC" -O2 -Wall -Wextra -Werror "$HERE/fake_player.c" -o "$TMP/player"
"$TMP/features"
"$TMP/synth"
python3 "$ERM/test/phrase_voice_isolated/protocol_test.py" "$TMP/native" "$TMP/capture"
python3 "$HERE/protocol_test.py" "$TMP/lab" "$TMP/native" "$TMP/capture" "$TMP/player"
python3 "$HERE/build_test.py"
echo 'Native checks complete: 16 phrase + 12 synthesis + 6 legacy protocol + 9 lab protocol + 5 build checks.'
# Optional native core memory/undefined-behaviour checking.
if [ "${SANITIZE:-0}" = 1 ]; then
    for test in features synth; do
        case "$test" in
            features) SOURCE="$ERM/test/phrase_voice_isolated/features_test.cpp" ;;
            synth) SOURCE="$HERE/synth_test.cpp" ;;
        esac
        "$CXX" -std=c++17 -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
            -fsanitize=address,undefined -I"$ERM/c_src" "$SOURCE" -o "$TMP/$test-san"
        ASAN_OPTIONS=detect_leaks=1 "$TMP/$test-san"
    done
fi
