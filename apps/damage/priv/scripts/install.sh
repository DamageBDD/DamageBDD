#!/usr/bin/env bash
# Canonical URL: https://run.damagebdd.com/install
# Install prebuilt Damage packages with bundled ERTS. Never build from source.
# Release API responses are DATA: never eval or source remote metadata.
set -Eeuo pipefail
export LC_ALL=C

RELEASE_VERSION="${DAMAGEBDD_VERSION:-latest}"
RELEASE_API="${DAMAGEBDD_RELEASE_API:-https://run.damagebdd.com/api/releases}"
IPFS_GATEWAY="${DAMAGEBDD_IPFS_GATEWAY:-https://ipfs.io/ipfs}"
EXPECTED_NETWORK="${DAMAGEBDD_RELEASE_NETWORK:-ae_mainnet}"
HEALTH_URL="${DAMAGEBDD_HEALTH_URL-http://127.0.0.1:4888/api/version}"
WORKDIR=""
LOG_DIR=/var/log/damagebdd
LOG_FILE="$LOG_DIR/install.log"
TOR_KEY_FPR=A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
TOR_REPO=https://deb.torproject.org/torproject.org
TOR_KEY_URL="$TOR_REPO/$TOR_KEY_FPR.asc"
# Own only our files, never overwrite an administrator's tor.sources/keyring.
TOR_SOURCE=/etc/apt/sources.list.d/damagebdd-tor.sources
TOR_KEYRING=/etc/apt/keyrings/damagebdd-tor.gpg
TOR_PACKAGE_KEYRING=/usr/share/keyrings/deb.torproject.org-keyring.gpg

log()  { printf '[damagebdd] %s\n' "$*" >&2; }
warn() { printf '[damagebdd] WARNING: %s\n' "$*" >&2; }
die()  { printf '[damagebdd] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
DamageBDD NFT-backed production installer

  curl -fsSL https://run.damagebdd.com/install | sudo bash
  sudo env DAMAGEBDD_VERSION=v1.4.1 bash ./install.sh

Environment (set on bash/sudo, not on the curl side of a pipeline):
  DAMAGEBDD_VERSION            latest, or an exact published NFT release name
  DAMAGEBDD_RELEASE_PLATFORM   Explicit target override (otherwise OS/base/arch)
  DAMAGEBDD_RELEASE_API        HTTPS API base ending /api/releases
  DAMAGEBDD_RELEASE_NETWORK   Expected network, default ae_mainnet
  DAMAGEBDD_RELEASE_CONTRACT  Optional expected source NFT contract ID
  DAMAGEBDD_RELEASE_INDEX     Optional expected discovery index contract ID
  DAMAGEBDD_IPFS_GATEWAY      HTTPS gateway base ending /ipfs
  DAMAGEBDD_HEALTH_URL        Local health check URL (empty disables the check)

Explicit package bypass (BOTH values are required, no automatic fallback):
  DAMAGEBDD_DEB_URL,  DAMAGEBDD_DEB_SHA256
  DAMAGEBDD_ARCH_URL, DAMAGEBDD_ARCH_SHA256

Supported package backends: Debian/Ubuntu/Ubuntu-based Mint/Pop; Arch family.
Other operating systems fail before modifying the host. ERTS is bundled in
release packages; neither Erlang nor rebar3 is installed on the target.
HELP
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Use sudo bash install.sh, or pipe /install into sudo bash."
}
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }
valid_version() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,159}$ ]]; }
valid_platform() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,95}$ ]]; }
valid_cid() { [[ "$1" =~ ^Qm[1-9A-HJ-NP-Za-km-z]{44}$ || "$1" =~ ^b[a-z2-7]{20,127}$ ]]; }
valid_ct() { [[ "$1" =~ ^ct_[1-9A-HJ-NP-Za-km-z]{40,60}$ ]]; }
valid_asset_path() {
    local path="$1" part
    [ -z "$path" ] && return 0
    [ "${#path}" -le 512 ] || return 1
    [[ "$path" != /* && "$path" != */ && "$path" != *//* ]] || return 1
    local -a parts=()
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[A-Za-z0-9._+-]+$ && "$part" != . && "$part" != .. ]] || return 1
    done
}
require_https() {
    local url="$1"
    [[ "$url" =~ ^https://[^/?#@]+(/[^?#]*)?$ && "$url" != *[$'\n\r\t ']* ]] ||
        die "Only HTTPS URLs without credentials, query strings or fragments are accepted here."
}

# Pure dispatch helper, also exercised by the offline tests. Debian package
# architecture is supplied by dpkg, not guessed from a 64-bit kernel.
classify_platform() {
    local kernel="$1" id="$2" like="$3" suite="$4" ubuntu_suite="$5" arch="$6"
    PACKAGE_KIND=""; BASE_SUITE=""; RELEASE_PLATFORM=""; PACKAGE_ARCH="$arch"
    [ "$kernel" = Linux ] || die "No production package backend for $kernel yet."
    case "$id" in
        ubuntu|debian|linuxmint|pop) PACKAGE_KIND=deb ;;
        arch|manjaro|endeavouros) PACKAGE_KIND=arch ;;
        *)
            case " $like " in
                *" ubuntu "*|*" debian "*) PACKAGE_KIND=deb ;;
                *" arch "*) PACKAGE_KIND=arch ;;
                *) die "Unsupported Linux distribution: $id" ;;
            esac ;;
    esac
    if [ "$PACKAGE_KIND" = deb ]; then
        case "$id" in
            ubuntu) BASE_SUITE="$suite"; RELEASE_PLATFORM="ubuntu-$suite-$arch" ;;
            debian) BASE_SUITE="$suite"; RELEASE_PLATFORM="debian-$suite-$arch" ;;
            linuxmint|pop)
                # Do not use Mint's wilma/xia/... as an Ubuntu repository suite.
                BASE_SUITE="$ubuntu_suite"
                [ -z "$BASE_SUITE" ] || RELEASE_PLATFORM="ubuntu-$BASE_SUITE-$arch" ;;
        esac
    else
        RELEASE_PLATFORM="archlinux-$arch"
    fi
    RELEASE_PLATFORM="${DAMAGEBDD_RELEASE_PLATFORM:-$RELEASE_PLATFORM}"
    valid_platform "$RELEASE_PLATFORM" ||
        die "Cannot determine an ABI-safe target; set DAMAGEBDD_RELEASE_PLATFORM explicitly."
    [[ "$PACKAGE_ARCH" =~ ^[a-z0-9_]+$ ]] || die "Invalid package architecture."
}

detect_platform() {
    local kernel id like suite ubuntu_suite native_arch
    kernel="$(uname -s)"
    [ "$kernel" = Linux ] || die "No production package backend for $kernel yet."
    # A subshell prevents os-release's VERSION from clobbering release settings.
    local -a os=()
    local line
    while IFS= read -r line; do os+=("$line"); done < <(
        if [ -r /etc/os-release ]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            printf '%s\n' "${ID:-unknown}" "${ID_LIKE:-}" "${VERSION_CODENAME:-}" "${UBUNTU_CODENAME:-}"
        else
            printf 'unknown\n\n\n\n'
        fi
    )
    id="${os[0]}"; like="${os[1]}"; suite="${os[2]}"; ubuntu_suite="${os[3]}"
    native_arch="$(uname -m)"
    case "$id $like" in
        *debian*|*ubuntu*|*linuxmint*|*pop*)
            require_command dpkg
            native_arch="$(dpkg --print-architecture)" ;;
    esac
    classify_platform "$kernel" "$id" "$like" "$suite" "$ubuntu_suite" "$native_arch"
    log "target=$RELEASE_PLATFORM package=$PACKAGE_KIND architecture=$PACKAGE_ARCH"
}

setup_logging() {
    umask 077
    install -d -o 0 -m 0700 "$LOG_DIR"
    [ ! -L "$LOG_FILE" ] && [ ! -L "$LOG_FILE.prev" ] || die "Refusing symlinked install log."
    if [ -f "$LOG_FILE" ]; then mv -f "$LOG_FILE" "$LOG_FILE.prev"; fi
    : > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    # Never dump the environment, shell arguments or node secrets into logs.
    log "Production installation started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
cleanup() { if [ -n "$WORKDIR" ]; then rm -rf -- "$WORKDIR"; fi; }
mkworkdir() {
    WORKDIR="$(mktemp -d -t damagebdd-install.XXXXXXXX)"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

download() {
    local url="$1" out="$2"
    require_https "$url"
    curl -q --fail --location --silent --show-error \
        --proto '=https' --proto-redir '=https' --max-redirs 4 \
        --connect-timeout 15 --max-time 1800 --retry 3 \
        --output "$out" "$url"
}
verify_sha256() {
    local file="$1" expected="$2" actual
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "A valid SHA-256 is mandatory."
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || die "Package SHA-256 mismatch; refusing installation."
    log "Package SHA-256 verified."
}

# Exact, non-executable twelve-line manifest. No jq, eval, source, or repeated
# latest lookups (which could otherwise mix two different releases).
parse_install_manifest() {
    local file="$1" line
    [ "$(wc -c < "$file")" -le 8192 ] || die "Release manifest is oversized."
    cmp -s "$file" <(tr -d '\000-\011\013-\037\177' < "$file") ||
        die "Release manifest contains control characters."
    local -a fields=()
    while IFS= read -r line || [ -n "$line" ]; do fields+=("$line"); done < "$file"
    [ "${#fields[@]}" -eq 12 ] || die "Invalid release manifest field count."
    [ "${fields[0]}" = damagebdd-install-v1 ] || die "Unsupported release manifest schema."
    [ "${fields[1]}" = "$EXPECTED_NETWORK" ] || die "Release network does not match."
    valid_ct "${fields[2]}" && valid_ct "${fields[3]}" || die "Invalid release contract ID."
    [[ "${fields[4]}" =~ ^(0|[1-9][0-9]{0,38})$ ]] || die "Invalid release token."
    valid_version "${fields[5]}" && [ "${fields[5]}" != latest ] || die "Invalid release name."
    [ "${fields[6]}" = "$RELEASE_PLATFORM" ] || die "Release platform does not match this host."
    [[ -z "${fields[7]}" || "${fields[7]}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "Invalid Git SHA."
    valid_cid "${fields[8]}" && valid_cid "${fields[9]}" || die "Invalid release CID syntax."
    valid_asset_path "${fields[10]}" || die "Unsafe package path in release manifest."
    [[ "${fields[11]}" =~ ^[0-9a-f]{64}$ ]] || die "Release has no valid package SHA-256."
    if [ "$RELEASE_VERSION" != latest ]; then
        [ "${fields[5]}" = "$RELEASE_VERSION" ] || die "Server returned the wrong release version."
    fi
    if [ -n "${DAMAGEBDD_RELEASE_CONTRACT:-}" ]; then
        [ "${fields[3]}" = "$DAMAGEBDD_RELEASE_CONTRACT" ] || die "NFT contract pin mismatch."
    fi
    if [ -n "${DAMAGEBDD_RELEASE_INDEX:-}" ]; then
        [ "${fields[2]}" = "$DAMAGEBDD_RELEASE_INDEX" ] || die "Release index pin mismatch."
    fi
    ARTIFACT_SHA256="${fields[11]}"
    ARTIFACT_URL="${IPFS_GATEWAY%/}/${fields[9]}"
    [ -z "${fields[10]}" ] || ARTIFACT_URL="$ARTIFACT_URL/${fields[10]}"
    log "Resolved release=${fields[5]} token=${fields[4]} nft=${fields[3]}"
}

resolve_package() {
    local explicit_url explicit_sha
    case "$PACKAGE_KIND" in
        deb) explicit_url="${DAMAGEBDD_DEB_URL:-}"; explicit_sha="${DAMAGEBDD_DEB_SHA256:-}" ;;
        arch) explicit_url="${DAMAGEBDD_ARCH_URL:-}"; explicit_sha="${DAMAGEBDD_ARCH_SHA256:-}" ;;
    esac
    if [ -n "$explicit_url" ]; then
        [[ "$explicit_sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "Explicit package URL requires its SHA-256."
        require_https "$explicit_url"
        warn "Explicit package URL selected; NFT discovery is bypassed."
        ARTIFACT_URL="$explicit_url"
        ARTIFACT_SHA256="$(printf '%s' "$explicit_sha" | tr A-F a-f)"
        return
    fi
    [ -z "$explicit_sha" ] || die "Checksum override without a package URL is ambiguous."
    require_https "$RELEASE_API"
    require_https "$IPFS_GATEWAY"
    valid_version "$RELEASE_VERSION" || die "Invalid requested release name."
    local manifest="$WORKDIR/release.txt"
    # Failed/empty/unavailable discovery is fatal. Never guess a mutable URL.
    curl -q --fail --silent --show-error \
        --proto '=https' --connect-timeout 15 --max-time 60 --retry 2 \
        --get --data-urlencode "platform=$RELEASE_PLATFORM" \
        --data-urlencode 'format=install' \
        --output "$manifest" "${RELEASE_API%/}/$RELEASE_VERSION" ||
        die "Release discovery failed; no package was selected."
    parse_install_manifest "$manifest"
}

ensure_debian_tools() {
    export DEBIAN_FRONTEND=noninteractive
    require_command apt-get
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
}
tor_deb_installed() {
    dpkg-query -W -f='${Status}\n' tor 2>/dev/null | grep -q '^install ok installed$'
}
use_packaged_tor_keyring() {
    # The installed keyring package receives future signing-key rotations.
    # Only called for the source created by THIS run, never an admin source.
    if [ ! -r "$TOR_PACKAGE_KEYRING" ]; then
        warn "Packaged Tor keyring is absent; retaining the verified bootstrap key."
        return
    fi
    awk -v key="$TOR_PACKAGE_KEYRING" '
        /^Signed-By:/ {print "Signed-By: " key; next} {print}
    ' "$TOR_SOURCE" > "$WORKDIR/tor.sources.package-keyring"
    install -o root -g root -m 0644 "$WORKDIR/tor.sources.package-keyring" "$TOR_SOURCE" ||
        die "Cannot switch Tor source to its package-maintained keyring."
    rm -f "$TOR_KEYRING"
}
try_torproject_debian() {
    [[ "$PACKAGE_ARCH" = amd64 || "$PACKAGE_ARCH" = arm64 ]] || return 1
    [[ "$BASE_SUITE" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    if [ -e "$TOR_SOURCE" ] || [ -e "$TOR_KEYRING" ]; then
        # A previous/admin-managed file is not ours to overwrite or delete.
        warn "Tor source/keyring already exists; preserving configured APT sources."
        return 1
    fi
    curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 10 --max-time 30 --output /dev/null \
        "$TOR_REPO/dists/$BASE_SUITE/InRelease" || return 1
    local asc="$WORKDIR/tor.asc" key="$WORKDIR/tor.gpg" fingerprint
    download "$TOR_KEY_URL" "$asc" || return 1
    fingerprint="$(gpg --batch --show-keys --with-colons "$asc" 2>/dev/null |
        awk -F: '$1 == "fpr" && !found {print $10; found=1}')" || return 1
    [ "$fingerprint" = "$TOR_KEY_FPR" ] || die "Tor signing-key fingerprint mismatch."
    gpg --batch --yes --dearmor --output "$key" "$asc" || return 1
    install -d -o root -g root -m 0755 /etc/apt/keyrings || return 1
    install -o root -g root -m 0644 "$key" "$TOR_KEYRING" || return 1
    cat > "$TOR_SOURCE" <<TOR
Types: deb
URIs: $TOR_REPO
Suites: $BASE_SUITE
Components: main
Architectures: $PACKAGE_ARCH
Signed-By: $TOR_KEYRING
TOR
    chmod 0644 "$TOR_SOURCE" || die "Cannot set Tor source permissions."
    if apt-get update && apt-get install -y --no-install-recommends tor deb.torproject.org-keyring; then
        use_packaged_tor_keyring
        log "Tor installed with the Tor Project repository configured."
        return 0
    fi
    warn "Tor Project installation failed; removing only the files created by this run."
    rm -f "$TOR_SOURCE" "$TOR_KEYRING"
    return 1
}
ensure_tor_debian() {
    if tor_deb_installed; then log "Existing Tor package preserved."; return; fi
    if try_torproject_debian; then return; fi
    warn "Installing Tor from the administrator's configured distribution sources."
    apt-get update
    apt-get install -y --no-install-recommends tor
}

has_bundled_erts() {
    # Consume all input: do not terminate the tar pipeline early under pipefail.
    awk '/(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {found=1} END {exit !found}'
}
validate_deb_package() {
    local package="$1" name arch
    name="$(dpkg-deb -f "$package" Package)"
    arch="$(dpkg-deb -f "$package" Architecture)"
    [ "$name" = damage ] || die "Downloaded DEB is not the damage package."
    [ "$arch" = "$PACKAGE_ARCH" ] || die "DEB architecture mismatch."
    dpkg-deb --fsys-tarfile "$package" | tar -tf - | has_bundled_erts ||
        die "Release DEB is missing bundled ERTS (beam.smp)."
}
validate_arch_package() {
    local package="$1" info name arch
    info="$(bsdtar -xOf "$package" .PKGINFO)"
    name="$(printf '%s\n' "$info" | awk -F' = ' '$1 == "pkgname" {print $2}')"
    arch="$(printf '%s\n' "$info" | awk -F' = ' '$1 == "arch" {print $2}')"
    [ "$name" = damage ] || die "Downloaded Arch package is not damage."
    [ "$arch" = "$PACKAGE_ARCH" ] || die "Arch package architecture mismatch."
    bsdtar -tf "$package" | has_bundled_erts || die "Release package is missing bundled ERTS."
}
install_release() {
    local package
    case "$PACKAGE_KIND" in
        deb)
            ensure_debian_tools
            package="$WORKDIR/damage.deb" ;;
        arch)
            require_command pacman
            log "Arch prerequisites require a full system upgrade (not a partial refresh)."
            pacman -Syu --needed --noconfirm ca-certificates curl tor
            require_command bsdtar
            package="$WORKDIR/damage.pkg.tar.zst" ;;
    esac
    require_command sha256sum
    resolve_package
    download "$ARTIFACT_URL" "$package"
    verify_sha256 "$package" "$ARTIFACT_SHA256"
    case "$PACKAGE_KIND" in
        deb)
            validate_deb_package "$package"
            ensure_tor_debian
            apt-get install -y --no-install-recommends "$package" ;;
        arch)
            validate_arch_package "$package"
            pacman -U --needed --noconfirm "$package" ;;
    esac
}
post_install() {
    log "Production package installed; service/config/key lifecycle remains package-managed."
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl --no-pager --full status damage.service || true
    fi
    if [ -r /var/lib/damage/tor/hostname ]; then
        local onion
        onion="$(tr -d '\r\n' < /var/lib/damage/tor/hostname)"
        if [[ "$onion" =~ ^[a-z2-7]{56}\.onion$ ]]; then log "Onion address: http://$onion/"; fi
    fi
    if [ -n "$HEALTH_URL" ]; then
        if curl -q -fsS --connect-timeout 2 --max-time 5 "$HEALTH_URL" >/dev/null; then
            log "Version endpoint is responding."
        else
            warn "Package installed; version endpoint not yet reachable (check damage.service)."
        fi
    fi
    log "Install log: $LOG_FILE"
}
main() {
    case "${1:-}" in -h|--help) usage; return ;; "") ;; *) die "Unknown option: $1" ;; esac
    need_root
    detect_platform
    setup_logging
    mkworkdir
    install_release
    post_install
}
# Allows the test suite to source functions without installing anything. A
# piped `bash` has no BASH_SOURCE, and must still execute main at end-of-file.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" = "$0" ]]; then main "$@"; fi
