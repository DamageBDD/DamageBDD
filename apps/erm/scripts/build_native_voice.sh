#!/bin/sh
# Rebar compile/clean entry point. SDK downloads happen only when missing.
set -eu
voice_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WHISPER_PREFIX=${WHISPER_PREFIX:-"$HOME/.local/erm-voice/whisper"}
SHERPA_PREFIX=${SHERPA_PREFIX:-"$HOME/.local/erm-voice/sherpa-onnx"}
CXX=${CXX:-c++}
export WHISPER_PREFIX SHERPA_PREFIX CXX
case "${1:-compile}" in
    clean)
        exec make -C "$voice_dir/c_src" -f Makefile.native_voice TARGET=../priv/erm_native_voice clean ;;
    compile) ;;
    *) echo 'Usage: build_native_voice.sh [compile|clean]' >&2; exit 2 ;;
esac
case "${ERM_NATIVE_VOICE_AUTO_SETUP:-1}" in
    0|1) ;;
    *) echo 'ERM_NATIVE_VOICE_AUTO_SETUP must be 0 or 1' >&2; exit 2 ;;
esac
for voice_prefix in "$WHISPER_PREFIX" "$SHERPA_PREFIX"; do
    case "$voice_prefix" in
        /*) ;;
        *) echo "SDK prefix must be absolute: $voice_prefix" >&2; exit 2 ;;
    esac
done
for program in make flock; do
    command -v "$program" >/dev/null || { echo "Missing prerequisite: $program" >&2; exit 1; }
done
voice_cache=${XDG_CACHE_HOME:-"$HOME/.cache"}/erm-native-voice
mkdir -p "$voice_cache"
# Serialize SDK bootstrap and port writes across this user's rebar builds.
exec 9>"$voice_cache/build.lock"
flock 9
voice_bootstrapped=0
if ! test -f "$WHISPER_PREFIX/include/whisper.h" ||
   ! test -f "$WHISPER_PREFIX/lib/libwhisper.so" ||
   ! test -f "$SHERPA_PREFIX/include/sherpa-onnx/c-api/c-api.h" ||
   ! test -f "$SHERPA_PREFIX/lib/libsherpa-onnx-c-api.so" ||
   test -e "$WHISPER_PREFIX/.erm-native-voice-installing" ||
   test -e "$SHERPA_PREFIX/.erm-native-voice-installing"; then
    if test "${ERM_NATIVE_VOICE_AUTO_SETUP:-1}" = 0; then
        echo "Native voice SDKs missing; automatic setup is disabled." >&2
        echo "WHISPER_PREFIX=$WHISPER_PREFIX SHERPA_PREFIX=$SHERPA_PREFIX" >&2
        echo "Run sh $voice_dir/scripts/setup_native_voice.sh or provide installed SDK prefixes." >&2
        exit 1
    fi
    echo 'Native voice SDKs missing; building the pinned SDKs (first compile needs network access).'
    sh "$voice_dir/scripts/setup_native_voice.sh"
    voice_bootstrapped=1
fi
# Relink when compiler options or SDK paths change. Keep build metadata out of
# priv so it is not copied into a release. Update it only after a successful build.
voice_inputs=$(mktemp "$voice_cache/inputs.XXXXXXXX")
trap 'rm -f "$voice_inputs"' EXIT HUP INT TERM
printf '%s\n' "$WHISPER_PREFIX" "$SHERPA_PREFIX" "${CXX:-c++}" \
    "${CXXFLAGS:--O2 -Wall -Wextra}" "${CPPFLAGS:-}" "${LDFLAGS:-}" "$(uname -m)" > "$voice_inputs"
voice_saved="$voice_dir/c_src/.erm_native_voice.build"
voice_target="$voice_dir/priv/erm_native_voice"
set --
if test "$voice_bootstrapped" = 1; then
    : # setup has already linked the port with these compiler options and SDKs
elif ! cmp -s "$voice_inputs" "$voice_saved"; then
    set -- -B
elif test -f "$voice_target" && test -n "$(find -L \
    "$WHISPER_PREFIX/include" "$WHISPER_PREFIX/lib" \
    "$SHERPA_PREFIX/include" "$SHERPA_PREFIX/lib" \
    -type f -newer "$voice_target" -print -quit)"; then
    set -- -B
fi
make "$@" -C "$voice_dir/c_src" -f Makefile.native_voice \
    CXX="${CXX:-c++}" WHISPER_PREFIX="$WHISPER_PREFIX" SHERPA_PREFIX="$SHERPA_PREFIX" \
    TARGET=../priv/erm_native_voice
test -x "$voice_target"
cp "$voice_inputs" "$voice_saved"
