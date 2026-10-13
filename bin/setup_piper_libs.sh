#!/usr/bin/env bash
# Native Piper SDK for erm. No Python or pip dependency.
# Upstream: https://github.com/OHF-Voice/piper1-gpl/tree/main/libpiper
set -Eeuo pipefail
trap 'printf "ERROR: setup failed at line %s. Build files retained in %s\n" "$LINENO" "${work_dir:-not-created}" >&2' ERR

prefix=${PIPER_PREFIX:-/opt/piper}
ref=${PIPER_REF:-efffbfb226bfb511ebbcf55d0cecd8b35a89743d}
jobs=${PIPER_JOBS:-4}
install_deps=false
resume_dir=
usage() {
    cat <<'HELP'
Usage: bash setup_piper_libs.sh [options]
  --install-deps       Install build tools using pacman or apt-get (may use sudo)
  --prefix PATH        Install prefix (default: /opt/piper or PIPER_PREFIX)
  --ref REF            Upstream commit, tag or branch (default: pinned commit or PIPER_REF)
  --jobs N             Parallel build jobs (default: 4 or PIPER_JOBS)
  --resume PATH       Repair/reuse a previous build directory (keeps its commit)
  --help              Show this help

Run as your normal user; sudo is used only for packages and protected installs.
Existing piper/piper-tts packages are not removed or replaced.
No voice models are downloaded. Reuse a recorded commit with --ref for rebuilds.
HELP
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --install-deps) install_deps=true; shift ;;
        --prefix|--ref|--jobs|--resume)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in --prefix) prefix=$2;; --ref) ref=$2;; --jobs) jobs=$2;; --resume) resume_dir=$2;; esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ $(uname -s) == Linux ]] || die 'This installer targets Linux.'
[[ $prefix == /* && $prefix != / ]] || die 'Use an absolute dedicated prefix, not /.'
[[ $prefix != *$'\n'* && $prefix != *';'* ]] || die 'Prefix cannot contain newlines or semicolons.'
[[ -n $ref && $ref != -* ]] || die 'Invalid Git reference.'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer.'

privileged() {
    if (( EUID == 0 )); then "$@";
    else command -v sudo >/dev/null || die 'sudo is required for this install prefix.'; sudo -- "$@"; fi
}
if $install_deps; then
    if command -v pacman >/dev/null; then
        # Do not install the unrelated Arch mouse configuration package "piper".
        privileged pacman -S --needed base-devel cmake git pkgconf
    elif command -v apt-get >/dev/null; then
        privileged apt-get update
        privileged apt-get install build-essential cmake git pkg-config
    else
        die 'Install a C/C++ compiler, make, CMake >= 3.26, git and pkg-config with your package manager.'
    fi
fi
for tool in git cmake cc c++ make; do
    command -v "$tool" >/dev/null || die "Missing $tool; install build tools or use --install-deps."
done

cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/erm-piper
mkdir -p "$cache_root"
if [[ -n $resume_dir ]]; then
    [[ -d $resume_dir/source/.git && -f $resume_dir/source/libpiper/CMakeLists.txt ]] || die 'Resume path is not a Piper setup build directory.'
    work_dir=$(cd "$resume_dir" && pwd -P)
else
    work_dir=$(mktemp -d "$cache_root/build.XXXXXXXX")
fi
# CMake validates its own version without requiring Python for comparison.
printf 'cmake_minimum_required(VERSION 3.26)\n' > "$work_dir/check-cmake.cmake"
cmake -P "$work_dir/check-cmake.cmake"
printf 'Build directory: %s\n' "$work_dir"
if [[ -z $resume_dir ]]; then
    printf 'Fetching upstream ref: %s\n' "$ref"
    git init -q "$work_dir/source"
    git -C "$work_dir/source" remote add origin https://github.com/OHF-Voice/piper1-gpl.git
    git -C "$work_dir/source" fetch --depth 1 origin "$ref"
    git -C "$work_dir/source" checkout --detach FETCH_HEAD
fi
revision=$(git -C "$work_dir/source" rev-parse HEAD)
printf 'Resolved Piper commit: %s\n' "$revision"

# Upstream find_library(PATHS ...) searches system directories first.
# Restrict this lookup to the downloaded SDK; otherwise system ONNX can be
# linked while a different bundled ONNX is installed. Clear the old cache too.
piper_cmake=$work_dir/source/libpiper/CMakeLists.txt
original_lookup='find_library(ONNXRUNTIME_LIB NAMES onnxruntime PATHS ${ONNXRUNTIME_DIR}/lib REQUIRED)'
fixed_lookup='find_library(ONNXRUNTIME_LIB NAMES onnxruntime PATHS "${ONNXRUNTIME_DIR}/lib" NO_DEFAULT_PATH REQUIRED)'
if grep -Fq "$original_lookup" "$piper_cmake"; then
    sed -i 's/find_library(ONNXRUNTIME_LIB NAMES onnxruntime PATHS ${ONNXRUNTIME_DIR}\/lib REQUIRED)/find_library(ONNXRUNTIME_LIB NAMES onnxruntime PATHS "${ONNXRUNTIME_DIR}\/lib" NO_DEFAULT_PATH REQUIRED)/' "$piper_cmake"
fi
grep -Fq "$fixed_lookup" "$piper_cmake" || die 'Upstream ONNX lookup changed; refusing an unverified system-library fallback.'

cmake -S "$work_dir/source/libpiper" -B "$work_dir/build" \
    -G 'Unix Makefiles' \
    -U ONNXRUNTIME_LIB \
    -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_INSTALL_PREFIX=$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_DATAROOTDIR=share \
    '-DCMAKE_INSTALL_RPATH=$ORIGIN' \
    -DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime=TRUE \
    -DBUILD_SHARED_LIBS=ON
onnx_lib=$(sed -n 's/^ONNXRUNTIME_LIB:FILEPATH=//p' "$work_dir/build/CMakeCache.txt")
case "$onnx_lib" in
    "$work_dir/source/libpiper/lib/"*) ;;
    *) die "Unexpected ONNX link target: $onnx_lib" ;;
esac
[[ -f $onnx_lib ]] || die "ONNX library is missing: $onnx_lib"
printf 'ONNX link target: %s\n' "$onnx_lib"
cmake --build "$work_dir/build" --parallel "$jobs"
# Stage and validate before writing into the requested prefix.
stage=$(mktemp -d "$work_dir/stage.XXXXXXXX")
cmake --install "$work_dir/build" --prefix "$stage"
[[ -f $stage/include/piper.h ]] || die 'Upstream installation did not supply include/piper.h.'
[[ -f $stage/lib/libpiper.so ]] || die 'Upstream installation did not supply lib/libpiper.so.'
[[ -f $stage/lib/libonnxruntime.so ]] || die 'Upstream installation did not bundle lib/libonnxruntime.so.'
[[ -d $stage/share/espeak-ng-data ]] || die 'Upstream installation did not supply share/espeak-ng-data.'

cat > "$work_dir/probe.cpp" <<'CPP'
#include <piper.h>
int main() {
    auto volatile create = &piper_create;
    auto volatile defaults = &piper_default_synthesize_options;
    auto volatile start = &piper_synthesize_start;
    auto volatile next = &piper_synthesize_next;
    auto volatile release = &piper_free;
    return (create && defaults && start && next && release) ? 0 : 1;
}
CPP
c++ -std=c++17 "$work_dir/probe.cpp" -I"$stage/include" \
    -L"$stage/lib" -Wl,--no-as-needed -lpiper -lonnxruntime \
    "-Wl,-rpath,$stage/lib" -o "$work_dir/probe"
LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work_dir/probe"

mkdir -p "$stage/share/erm-piper"
printf '%s\n' "$revision" > "$stage/share/erm-piper/source-commit.txt"
printf '%s\n' 'Local CMake fix: ONNXRUNTIME_LIB lookup uses NO_DEFAULT_PATH.' > "$stage/share/erm-piper/build-fixes.txt"
git -C "$work_dir/source" ls-tree -r HEAD --name-only | while IFS= read -r name; do
    case "$name" in
        LICENSE*|COPYING*) cp "$work_dir/source/$name" "$stage/share/erm-piper/" ;;
    esac
done
# Build as the caller; elevate only the copy if the prefix is protected.
if [[ -d $prefix && -w $prefix ]] || [[ ! -e $prefix && -w $(dirname "$prefix") ]]; then
    mkdir -p "$prefix"
    cp -a "$stage/." "$prefix/"
else
    privileged mkdir -p "$prefix"
    privileged cp -a "$stage/." "$prefix/"
fi
# Check the installed libraries, not just the staging directory.
c++ -std=c++17 "$work_dir/probe.cpp" -I"$prefix/include" \
    -L"$prefix/lib" -Wl,--no-as-needed -lpiper -lonnxruntime \
    "-Wl,--disable-new-dtags,-rpath,$prefix/lib" -o "$work_dir/installed-probe"
"$work_dir/installed-probe"
printf '\nNative Piper SDK installed and link/load check passed.\n'
printf 'Headers:     %s/include\nLibraries:   %s/lib\neSpeak data: %s/share/espeak-ng-data\n' "$prefix" "$prefix" "$prefix"
printf 'Commit:      %s\nBuild cache: %s\n\n' "$revision" "$work_dir"
printf 'From your DamageBDD repository, using the updated tts profile:\n  PIPER_PREFIX=%q rebar3 as tts compile\n' "$prefix"
printf '\nFor releases:\n  PIPER_PREFIX=%q rebar3 as prod,tts release\n' "$prefix"
printf '\nSet erm tts espeak_data to: %s/share/espeak-ng-data\n' "$prefix"
printf 'Voice model, matching .onnx.json and MPV must be configured separately.\n'
