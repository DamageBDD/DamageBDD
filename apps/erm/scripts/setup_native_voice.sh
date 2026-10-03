#!/bin/sh
# Build private CPU SDKs without Python. Run as your normal build user.
set -eu
WHISPER_PREFIX=${WHISPER_PREFIX:-"$HOME/.local/erm-voice/whisper"}
SHERPA_PREFIX=${SHERPA_PREFIX:-"$HOME/.local/erm-voice/sherpa-onnx"}
WHISPER_REV=${WHISPER_REV:-6e4ab854f67f743900934a703d5603419384c961}
SHERPA_REV=${SHERPA_REV:-040afe360a38e25daaa325ce8889abf93ea02609}
JOBS=${JOBS:-4}
for program in git cmake make c++; do command -v "$program" >/dev/null || { echo "Missing prerequisite: $program" >&2; exit 1; }; done
case "$WHISPER_PREFIX:$SHERPA_PREFIX" in /*:/*) ;; *) echo 'Prefixes must be absolute' >&2; exit 1;; esac
voice_cache=${XDG_CACHE_HOME:-"$HOME/.cache"}/erm-native-voice
mkdir -p "$voice_cache"
voice_build=$(mktemp -d "$voice_cache/build.XXXXXXXX")
echo "Build files: $voice_build (retained for diagnostics)"
fetch() {
    git init -q "$1"
    git -C "$1" fetch --depth 1 "$2" "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}
fetch "$voice_build/whisper" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_REV"
cmake -S "$voice_build/whisper" -B "$voice_build/whisper-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WHISPER_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_RPATH="$WHISPER_PREFIX/lib" \
    -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DGGML_CUDA=OFF -DGGML_NATIVE=OFF
cmake --build "$voice_build/whisper-build" --parallel "$JOBS"
cmake --install "$voice_build/whisper-build"
fetch "$voice_build/sherpa" https://github.com/k2-fsa/sherpa-onnx.git "$SHERPA_REV"
cmake -S "$voice_build/sherpa" -B "$voice_build/sherpa-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$SHERPA_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_RPATH="$SHERPA_PREFIX/lib" \
    -DBUILD_SHARED_LIBS=ON -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
    -DSHERPA_ONNX_ENABLE_GPU=OFF \
    -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF
cmake --build "$voice_build/sherpa-build" --parallel "$JOBS"
cmake --install "$voice_build/sherpa-build"
test -f "$WHISPER_PREFIX/include/whisper.h"
test -f "$SHERPA_PREFIX/include/sherpa-onnx/c-api/c-api.h"
test -f "$WHISPER_PREFIX/lib/libwhisper.so"
test -f "$SHERPA_PREFIX/lib/libsherpa-onnx-c-api.so"
echo 'SDKs installed. Use these same prefixes for rebar3 and on the runtime host:'
printf 'WHISPER_PREFIX=%s\nSHERPA_PREFIX=%s\n' "$WHISPER_PREFIX" "$SHERPA_PREFIX"
echo 'rebar3 as native_voice compile  (or: rebar3 as prod,tts,native_voice release)'
