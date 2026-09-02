#!/usr/bin/env bash
set -u

failures=0

ok() { printf '  OK  %s\n' "$*"; }
warn() { printf ' WARN %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; failures=$((failures + 1)); }

need_command() {
  local cmd=$1
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $(command -v "$cmd")"
  else
    fail "$cmd is not installed"
  fi
}

printf 'Host tools\n'
for cmd in node npm java adb make; do
  need_command "$cmd"
done

if command -v node >/dev/null 2>&1; then
  node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
  if (( node_major >= 22 )); then
    ok "Node $(node --version) satisfies Capacitor 8"
  else
    fail "Node 22 or newer is required; found $(node --version)"
  fi
fi

if command -v java >/dev/null 2>&1; then
  java_line=$(java -version 2>&1 | head -n 1)
  if [[ $java_line == *'21.'* || $java_line == *'"21"'* ]]; then
    ok "$java_line"
  else
    warn "Expected JDK 21; found $java_line"
  fi
fi

sdk_root=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}
printf '\nAndroid SDK\n'
printf ' INFO SDK root: %s\n' "$sdk_root"

sdkmanager=''
for candidate in \
  "$(command -v sdkmanager 2>/dev/null || true)" \
  "$sdk_root/cmdline-tools/latest/bin/sdkmanager" \
  "$sdk_root/cmdline-tools/bin/sdkmanager"; do
  if [[ -n $candidate && -x $candidate ]]; then
    sdkmanager=$candidate
    break
  fi
done

if [[ -n $sdkmanager ]]; then
  ok "sdkmanager: $sdkmanager"
else
  fail "sdkmanager was not found under $sdk_root"
fi

for component in platforms/android-36 build-tools/35.0.0 platform-tools; do
  if [[ -e $sdk_root/$component ]]; then
    ok "$component"
  else
    fail "missing SDK component: $component"
  fi
done

if [[ -s $sdk_root/licenses/android-sdk-license ]]; then
  ok "Android SDK license file exists"
else
  fail "Android SDK licences are not accepted in $sdk_root"
fi

printf '\nADB devices\n'
if command -v adb >/dev/null 2>&1; then
  adb devices -l || true
fi

if (( failures > 0 )); then
  printf '\n%d required check(s) failed.\n' "$failures" >&2
  if [[ -n $sdkmanager ]]; then
    printf 'Install/accept SDK components with:\n' >&2
    printf '  sudo %q --sdk_root=%q %q %q %q\n' \
      "$sdkmanager" "$sdk_root" 'build-tools;35.0.0' 'platforms;android-36' 'platform-tools' >&2
    printf '  yes | sudo %q --sdk_root=%q --licenses\n' "$sdkmanager" "$sdk_root" >&2
  fi
  exit 1
fi

printf '\nEnvironment is ready.\n'
