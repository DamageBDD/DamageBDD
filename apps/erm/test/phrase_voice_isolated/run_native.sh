#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ERM=$(CDPATH= cd -- "$HERE/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CXX=${CXX:-c++}
"$CXX" -std=c++17 -O2 -Wall -Wextra -Werror -I"$ERM/c_src" "$HERE/features_test.cpp" -o "$TMP/features"
"$TMP/features"
# Adapt only SDK fixtures; compile the actual production worker without changes.
cp -R "$ERM/test/native_voice_isolated/sdk" "$TMP/sdk"
python3 - "$TMP/sdk" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1])/'whisper.h'
s=p.read_text().replace('static whisper_context ctx; return &ctx;',
    'if (std::getenv("PHRASE_TEST_FORBID_WHISPER")) { std::abort(); } static whisper_context ctx; return &ctx;')
s=s.replace('return std::getenv("NATIVE_TEST_WHISPER_FAIL")',
    'if (std::getenv("PHRASE_TEST_FORBID_WHISPER")) { std::abort(); } return std::getenv("NATIVE_TEST_WHISPER_FAIL")')
p.write_text(s)
p=Path(sys.argv[1])/'sherpa-onnx/c-api/c-api.h'
s=p.read_text().replace('#include <algorithm>','#include <algorithm>\n#include <unistd.h>')
s=s.replace('p->samples.size() < 2048','p->samples.size() < 24064')
s=s.replace('return new float[2]{1,0};','usleep(80000); return new float[2]{1,0};')
p.write_text(s)
PY
"$CXX" -std=c++17 -O2 -pthread -Wall -Wextra -Werror -I"$TMP/sdk" \
    "$ERM/c_src/erm_native_voice.cpp" -o "$TMP/native"
cc -O2 -Wall -Wextra -Werror "$ERM/test/native_voice_isolated/fake_capture.c" -o "$TMP/capture"
python3 "$HERE/protocol_test.py" "$TMP/native" "$TMP/capture"
