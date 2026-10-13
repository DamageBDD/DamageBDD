#!/bin/sh
# Compare the public installer response with a trusted manifest from the build.
# The manifest is DATA: never source/eval it or install a returned package here.
set -eu
export LC_ALL=C

fail() { printf '%s\n' "[release-check] $*" >&2; exit 1; }
[ "$#" -eq 3 ] || fail "Usage: $0 HTTPS_BASE_URL PLATFORM EXPECTED_INSTALL_MANIFEST"
BASE=${1%/}
PLATFORM=$2
EXPECTED=$3
case "$EXPECTED" in /*) ;; *) EXPECTED="./$EXPECTED" ;; esac
case "$BASE" in https://?*) ;; *) fail "An HTTPS base URL is required" ;; esac
case "$BASE" in *\?*|*\#*|*@*|*[[:space:]]*) fail "Base URL must not contain credentials, query, fragment or whitespace" ;; esac
case "$PLATFORM" in ''|*[!a-z0-9_-]*) fail "Invalid platform" ;; esac
[ "${#PLATFORM}" -le 96 ] || fail "Platform is too long"
[ -f "$EXPECTED" ] || fail "Expected manifest is not a regular file"

validate() {
    [ "$(wc -c < "$1")" -le 4096 ] || return 1
    awk -v platform="$PLATFORM" '
        NR == 1 && $0 != "damagebdd-install-v2" {bad=1}
        NR == 2 && ($0 !~ /^[a-z0-9_-]+$/ || length($0)>64) {bad=1}
        NR == 3 && $0 !~ /^ct_[A-Za-z0-9]+$/ {bad=1}
        NR == 4 && ($0 !~ /^[1-9][0-9]*$/ || length($0)>39) {bad=1}
        NR == 5 && ($0 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ || length($0)>160) {bad=1}
        NR == 6 && $0 != platform {bad=1}
        NR == 7 && $0 != "" && ($0 !~ /^[0-9a-f]+$/ || (length($0)!=40 && length($0)!=64)) {bad=1}
        (NR == 8 || NR == 9) && $0 !~ /^[A-Za-z0-9]+$/ {bad=1}
        NR == 10 && $0 != "" {
            if ($0 !~ /^[A-Za-z0-9][A-Za-z0-9._\/-]*$/) bad=1
            n=split($0, parts, "/")
            for (i=1; i<=n; i++) if (parts[i]=="" || parts[i]=="." || parts[i]=="..") bad=1
        }
        NR == 11 && ($0 !~ /^[0-9a-f]+$/ || length($0)!=64) {bad=1}
        END {exit (bad || NR!=11)}
    ' "$1"
}
validate "$EXPECTED" || fail "Expected manifest is malformed or targets another platform"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/damage-release-check.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
if ! STATUS=$(curl -q --silent --show-error --proto '=https' \
    --connect-timeout 15 --max-time 60 --max-filesize 4096 \
    --get --data-urlencode "platform=$PLATFORM" --data-urlencode 'format=install' \
    --output "$TMP/actual.install" --write-out '%{http_code}' \
    "$BASE/api/releases/latest"); then
    fail "Could not read release discovery (no fallback attempted)"
fi
[ "$STATUS" = 200 ] || fail "Release endpoint returned HTTP $STATUS (no fallback attempted)"
validate "$TMP/actual.install" || fail "Endpoint returned a malformed or wrong-platform manifest"
if ! cmp -s "$EXPECTED" "$TMP/actual.install"; then
    diff -u "$EXPECTED" "$TMP/actual.install" >&2 || true
    fail "Endpoint does not return the exact NFT/package identity produced by the build"
fi
printf '%s\n' "[release-check] Exact release identity verified for $PLATFORM at $BASE"
