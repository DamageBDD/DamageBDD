#!/bin/sh
# Build-system fixture only: no downloads, SDK compilation or audio processing.
set -eu
tool=$(basename -- "$0")
printf '%s\n' "$tool" >> "$NATIVE_BUILD_TEST_LOG"
case "$tool" in
    git)
        if test "$1" = init; then mkdir -p "$3"; fi ;;
    cmake)
        case "$1" in
            -S)
                shift
                build= prefix=
                while test "$#" -gt 0; do
                    case "$1" in
                        -B) shift; build=$1 ;;
                        -DCMAKE_INSTALL_PREFIX=*) prefix=${1#*=} ;;
                    esac
                    shift
                done
                mkdir -p "$build"
                printf '%s\n' "$prefix" > "$build/prefix" ;;
            --install)
                prefix=$(cat "$2/prefix")
                case "$2" in
                    */whisper-build)
                        mkdir -p "$prefix/include" "$prefix/lib"
                        echo fixture > "$prefix/include/whisper.h"
                        echo fixture > "$prefix/lib/libwhisper.so" ;;
                    */sherpa-build)
                        mkdir -p "$prefix/include/sherpa-onnx/c-api" "$prefix/lib"
                        echo fixture > "$prefix/include/sherpa-onnx/c-api/c-api.h"
                        echo fixture > "$prefix/lib/libsherpa-onnx-c-api.so" ;;
                esac
                test "${NATIVE_BUILD_FAIL_INSTALL:-0}" != 1 ;;
        esac ;;
    c++)
        test "${NATIVE_BUILD_FAIL_CXX:-0}" != 1
        target= whisper=0 sherpa=0
        while test "$#" -gt 0; do
            case "$1" in
                -o) shift; target=$1 ;;
                "-I$WHISPER_PREFIX/include") whisper=1 ;;
                "-I$SHERPA_PREFIX/include") sherpa=1 ;;
            esac
            shift
        done
        test "$whisper:$sherpa" = 1:1
        test -n "$target"
        printf '#!/bin/sh\nexit 0\n' > "$target"
        chmod +x "$target" ;;
    *) exit 2 ;;
esac
