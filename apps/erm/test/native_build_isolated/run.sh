#!/bin/sh
# Exercise actual config, hook scripts and Makefile using fake SDK build tools.
# Requires Erlang, GNU make and flock; no rebar plugins, SDKs, Python or network.
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_app=$(CDPATH= cd -- "$test_dir/../.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
app="$test_tmp/project with spaces/apps/erm"
mkdir -p "$app/scripts" "$app/c_src" "$test_tmp/bin"
cp "$source_app/rebar.config" "$source_app/rebar.config.script" "$app/"
cp "$source_app/scripts/build_native_voice.sh" "$source_app/scripts/setup_native_voice.sh" "$app/scripts/"
cp "$source_app/c_src/Makefile.native_voice" "$source_app/c_src/erm_native_voice.cpp" "$source_app/c_src/erm_voice_audio.h" "$app/c_src/"
cp "$test_dir/stub_tool.sh" "$test_tmp/bin/driver"
chmod +x "$test_tmp/bin/driver"
for tool in git cmake c++; do ln -s driver "$test_tmp/bin/$tool"; done
PATH="$test_tmp/bin:$PATH"
XDG_CACHE_HOME="$test_tmp/cache"
WHISPER_PREFIX="$test_tmp/sdk whisper"
SHERPA_PREFIX="$test_tmp/sdk sherpa"
CXX=c++
NATIVE_BUILD_TEST_LOG="$test_tmp/tools.log"
export PATH XDG_CACHE_HOME WHISPER_PREFIX SHERPA_PREFIX CXX NATIVE_BUILD_TEST_LOG
unset ERM_NATIVE_VOICE ERM_NATIVE_VOICE_AUTO_SETUP WHISPER_REV SHERPA_REV
unset CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS MFLAGS JOBS
unset NATIVE_BUILD_FAIL_CXX NATIVE_BUILD_FAIL_INSTALL
touch "$NATIVE_BUILD_TEST_LOG"
cd "$app"

# Evaluate the real rebar script, including composition with other app settings.
erl +S 2 -noshell -eval '
    {ok, Base} = file:consult("rebar.config"),
    Config = lists:keystore(artifacts, 1, Base, {artifacts, ["priv/existing"]}),
    Bindings = [{list_to_atom("CONFIG"), Config}],
    {ok, Enabled} = file:script("rebar.config.script", Bindings),
    ["priv/existing", "priv/erm_native_voice"] = proplists:get_value(artifacts, Enabled),
    [{compile, Compile}] = proplists:get_value(pre_hooks, Enabled),
    [{clean, Clean}] = proplists:get_value(post_hooks, Enabled),
    ok = file:write_file("compile-hook.sh", Compile),
    ok = file:write_file("clean-hook.sh", Clean),
    true = os:putenv("ERM_NATIVE_VOICE", "0"),
    {ok, Config} = file:script("rebar.config.script", Bindings),
    true = os:putenv("ERM_NATIVE_VOICE", "invalid"),
    {error, _} = file:script("rebar.config.script", Bindings),
    halt(0).'

count() { awk -v tool="$1" '$0 == tool {n++} END {print n+0}' "$NATIVE_BUILD_TEST_LOG"; }
expect_failure() {
    if "$@" > "$test_tmp/expected-failure.log" 2>&1; then
        echo 'Expected build failure, but command succeeded' >&2; exit 1
    fi
}

# Offline bootstrap fails before attempting any network/tool download.
expect_failure env ERM_NATIVE_VOICE_AUTO_SETUP=0 sh compile-hook.sh
test "$(count git)" = 0
sh compile-hook.sh > "$test_tmp/bootstrap.log" 2>&1
test -x priv/erm_native_voice
test "$(count c++)" = 1
git_calls=$(count git)
test "$git_calls" -gt 0

# A second compile, including offline mode, does no fetching or compiling.
env ERM_NATIVE_VOICE_AUTO_SETUP=0 sh compile-hook.sh
test "$(count git)" = "$git_calls"
test "$(count c++)" = 1

# Source and SDK changes, and changed compiler settings, each cause a relink.
# Move target back in time so these checks do not depend on filesystem resolution.
touch -t 200001010000 priv/erm_native_voice
sh compile-hook.sh
test "$(count c++)" = 2
touch -t 203001010000 "$SHERPA_PREFIX/lib/libsherpa-onnx-c-api.so"
sh compile-hook.sh
test "$(count c++)" = 3
touch -t 200001010000 "$SHERPA_PREFIX/lib/libsherpa-onnx-c-api.so"
env CXXFLAGS=-O0 sh compile-hook.sh
test "$(count c++)" = 4

# Failed linking keeps the previous worker and does not commit new build inputs.
old_inputs=$(cksum c_src/.erm_native_voice.build)
expect_failure env CXXFLAGS=-Os NATIVE_BUILD_FAIL_CXX=1 sh compile-hook.sh
test -x priv/erm_native_voice
test "$(cksum c_src/.erm_native_voice.build)" = "$old_inputs"
env CXXFLAGS=-Os sh compile-hook.sh
test "$(count c++)" = 6

# Clean removes build outputs, retains SDKs, then rebuilds offline without fetches.
sh clean-hook.sh
test ! -e priv/erm_native_voice
test ! -e c_src/.erm_native_voice.build
test -f "$WHISPER_PREFIX/lib/libwhisper.so"
env ERM_NATIVE_VOICE_AUTO_SETUP=0 sh compile-hook.sh
test "$(count git)" = "$git_calls"
test "$(count c++)" = 7

# Failed installation cannot be mistaken for a usable SDK on the next compile.
rm "$WHISPER_PREFIX/include/whisper.h"
expect_failure env NATIVE_BUILD_FAIL_INSTALL=1 sh compile-hook.sh
test -e "$WHISPER_PREFIX/.erm-native-voice-installing"
expect_failure env ERM_NATIVE_VOICE_AUTO_SETUP=0 sh compile-hook.sh
sh compile-hook.sh > "$test_tmp/recovery.log" 2>&1
test ! -e "$WHISPER_PREFIX/.erm-native-voice-installing"
test -x priv/erm_native_voice

echo 'PASS: config hooks, bootstrap, cached/offline builds, relinking, clean and failure recovery.'
