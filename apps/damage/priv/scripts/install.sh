#!/usr/bin/env bash
# DamageBDD production installer. Canonical route: https://run.damagebdd.com/install
# Prebuilt packages only. No source builds, system Erlang, or rebar3 bootstrap.
# Remote release manifests are DATA, never eval'ed or sourced.
set -Eeuo pipefail
export LC_ALL=C

RELEASE_VERSION="${DAMAGEBDD_VERSION:-latest}"
RELEASE_API="${DAMAGEBDD_RELEASE_API:-https://run.damagebdd.com/api/releases}"
IPFS_GATEWAY="${DAMAGEBDD_IPFS_GATEWAY:-https://ipfs.io/ipfs}"
EXPECTED_NETWORK="${DAMAGEBDD_RELEASE_NETWORK:-ae_mainnet}"
HEALTH_URL="${DAMAGEBDD_HEALTH_URL-http://127.0.0.1:4888/api/version}"
TOR_POLICY="${DAMAGEBDD_TOR_SOURCE:-auto}"
ASSUME_YES=0; CHECK_ONLY=0; PRINT_PLATFORM=0; START_SERVICE=0
WORKDIR=""; LOG_DIR=""; LOG_FILE=""; LOCK_HELD=0; ROLLING_UPGRADED=0
PACKAGE_KIND=""; PACKAGE_MANAGER=""; PACKAGE_ARCH=""; PACKAGE_VERSION=""
RELEASE_PLATFORM=""; BASE_SUITE=""; OS_ID=""; ANDROID_API=""
TOR_KEY_FPR=A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
TOR_REPO=https://deb.torproject.org/torproject.org
TOR_KEY_URL="$TOR_REPO/$TOR_KEY_FPR.asc"
TOR_SOURCE=/etc/apt/sources.list.d/damagebdd-tor.sources
TOR_KEYRING=/etc/apt/keyrings/damagebdd-tor.gpg
TOR_PACKAGE_KEYRING=/usr/share/keyrings/deb.torproject.org-keyring.gpg

log()  { printf '[damagebdd] %s\n' "$*" >&2; }
warn() { printf '[damagebdd] WARNING: %s\n' "$*" >&2; }
die()  { printf '[damagebdd] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }
usage() {
    cat <<'HELP'
DamageBDD NFT-backed production installer — Linux and native Termux

Linux:  curl -fsSL https://run.damagebdd.com/install | sudo bash -s -- --yes
Termux: curl -fsSL https://run.damagebdd.com/install | bash -s -- --yes

Options:
  --yes                    Approve package/dependency changes without a prompt
  --check                  Download and validate only; no package/service changes
  --print-platform         Print the release target; no network or changes
  --version NAME           latest (default), or exact published NFT release name
  --platform TARGET        Explicit ABI target; must retain native architecture
  --package-url HTTPS_URL  Bypass NFT discovery; requires --sha256
  --sha256 HEX             Mandatory digest for an explicit package URL
  --tor auto|system|official|skip
                           auto: prefer Tor Project on Debian/Ubuntu bases;
                           system: only configured repositories;
                           official: require Tor Project APT setup when missing;
                           skip: do not explicitly install Tor (package Depends
                           can still require it). Existing Tor is preserved.
  --start                  Explicitly enable/start the package-provided service
  -h, --help

Backends: APT (Debian/Ubuntu/Mint/Pop and derivatives); pacman (Arch family);
DNF/YUM (Fedora/RHEL/Rocky/Alma/CentOS and derivatives); Zypper (openSUSE/SLES);
APK (Alpine, signed format-v2 packages); native Termux APT (Android/Bionic).
Every target needs its OWN published compatible package, including bundled ERTS.
Immutable/OSTree systems, native Windows/macOS and source builds are not handled.
Termux requires non-root execution and a Termux-specific DEB, never a Debian DEB.

Environment (set on bash/sudo, NOT just on curl):
  DAMAGEBDD_VERSION, DAMAGEBDD_RELEASE_PLATFORM
  DAMAGEBDD_RELEASE_API       HTTPS base ending /api/releases
  DAMAGEBDD_IPFS_GATEWAY      HTTPS gateway base ending /ipfs
  DAMAGEBDD_RELEASE_NETWORK   Default: ae_mainnet
  DAMAGEBDD_RELEASE_CONTRACT  Optional expected NFT contract
  DAMAGEBDD_RELEASE_INDEX     Optional expected index contract
  DAMAGEBDD_PACKAGE_URL, DAMAGEBDD_PACKAGE_SHA256
  DAMAGEBDD_TOR_SOURCE, DAMAGEBDD_HEALTH_URL (empty disables health probe)
Legacy URL/digest pairs are also accepted: DAMAGEBDD_{DEB,ARCH,RPM,APK,TERMUX}_{URL,SHA256}.
--check requires the download and package-inspection tools to already be installed.
HELP
}

valid_version()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,159}$ ]]; }
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
    [[ "$1" =~ ^https://[^/?#@]+(/[^?#]*)?$ && "$1" != *[$'\n\r\t ']* ]] ||
        die "Expected HTTPS URL without credentials, query strings, fragments or whitespace."
}
parse_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --yes) ASSUME_YES=1; shift ;;
            --check) CHECK_ONLY=1; shift ;;
            --print-platform) PRINT_PLATFORM=1; shift ;;
            --start) START_SERVICE=1; shift ;;
            --version|--platform|--package-url|--sha256|--tor)
                [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value."
                case "$1" in
                    --version) RELEASE_VERSION="$2" ;;
                    --platform) DAMAGEBDD_RELEASE_PLATFORM="$2" ;;
                    --package-url) DAMAGEBDD_PACKAGE_URL="$2" ;;
                    --sha256) DAMAGEBDD_PACKAGE_SHA256="$2" ;;
                    --tor) TOR_POLICY="$2" ;;
                esac
                shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    valid_version "$RELEASE_VERSION" || die "Invalid requested release name."
    case "$TOR_POLICY" in auto|system|official|skip) ;; *) die "Invalid Tor source policy." ;; esac
    [ "$CHECK_ONLY:$START_SERVICE" != 1:1 ] || die "--check and --start cannot be combined."
}

# Termux must be detected before Linux/APT. Inherited TERMUX_VERSION or PREFIX
# alone is NOT enough: a proot guest with /usr/bin/dpkg is a Linux guest.
is_native_termux() {
    [[ "${PREFIX:-}" = /*/files/usr ]] &&
        [ -x "$PREFIX/bin/pkg" ] && [ -x "$PREFIX/bin/dpkg" ] &&
        [ "$(command -v dpkg 2>/dev/null)" = "$PREFIX/bin/dpkg" ] &&
        [ "$(command -v bash 2>/dev/null)" = "$PREFIX/bin/bash" ]
}
family_for() {
    local id="$1" like=" $2 "
    case "$id" in
        termux) printf termux ;;
        debian|ubuntu|linuxmint|pop|kali|parrot|raspbian|devuan|zorin|elementary|neon) printf deb ;;
        arch|archarm|manjaro|endeavouros|garuda|artix) printf arch ;;
        fedora|rhel|centos|rocky|almalinux|ol|amzn) printf rpm ;;
        opensuse*|sles|sled) printf suse ;;
        alpine) printf apk ;;
        *) case "$like" in
            *" ubuntu "*|*" debian "*) printf deb ;;
            *" arch "*) printf arch ;;
            *" suse "*|*" opensuse "*) printf suse ;;
            *" fedora "*|*" rhel "*|*" centos "*) printf rpm ;;
            *" alpine "*) printf apk ;;
            *) return 1 ;;
        esac ;;
    esac
}
# Pure target selection. Parameters are OS, ID, ID_LIKE, suite, Ubuntu base,
# VERSION_ID, and userspace package architecture (NOT blindly uname -m).
classify_platform() {
    local kernel="$1" id="$2" like="$3" suite="$4" ubuntu="$5" version="$6" arch="$7"
    local family release="${suite:-$version}"
    [ "$kernel" = Linux ] || die "Unsupported operating system: $kernel"
    family="$(family_for "$id" "$like")" || die "Unsupported Linux distribution: $id"
    PACKAGE_KIND="$family"; OS_ID="$id"; PACKAGE_ARCH="$arch"; BASE_SUITE=""
    RELEASE_PLATFORM=""; PACKAGE_MANAGER=""
    case "$family" in
        termux)
            PACKAGE_MANAGER=apt-get
            [[ "$arch" = aarch64 || "$arch" = arm || "$arch" = x86_64 || "$arch" = i686 ]] ||
                die "Unsupported Termux architecture: $arch"
            RELEASE_PLATFORM="termux-$arch" ;;
        deb)
            PACKAGE_MANAGER=apt-get
            if [ "$id" = ubuntu ] || [ "$id" = debian ]; then
                BASE_SUITE="$suite"
                [ -z "$release" ] || RELEASE_PLATFORM="$id-$release-$arch"
            elif [ -n "$ubuntu" ]; then
                BASE_SUITE="$ubuntu"; RELEASE_PLATFORM="ubuntu-$ubuntu-$arch"
            else
                # LMDE and other derivatives without a declared Ubuntu base
                # retain their own identity; never guess an Ubuntu codename.
                [ -z "$release" ] || RELEASE_PLATFORM="$id-$release-$arch"
            fi ;;
        arch)
            PACKAGE_MANAGER=pacman
            case "$id" in
                arch|archarm) RELEASE_PLATFORM="archlinux-$arch" ;;
                *) RELEASE_PLATFORM="$id-$arch" ;;
            esac ;;
        rpm)
            PACKAGE_MANAGER=dnf
            [ -z "$version" ] || RELEASE_PLATFORM="$id-$version-$arch" ;;
        suse)
            PACKAGE_KIND=rpm; PACKAGE_MANAGER=zypper
            case "$id" in
                opensuse-tumbleweed|opensuse-slowroll) RELEASE_PLATFORM="$id-$arch" ;;
                *) [ -z "$version" ] || RELEASE_PLATFORM="$id-$version-$arch" ;;
            esac ;;
        apk)
            PACKAGE_MANAGER=apk
            # Alpine compatibility target follows the repository major.minor.
            if [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
                RELEASE_PLATFORM="alpine-${BASH_REMATCH[1]}_${BASH_REMATCH[2]}-$arch"
            fi ;;
    esac
    RELEASE_PLATFORM="${DAMAGEBDD_RELEASE_PLATFORM:-${RELEASE_PLATFORM//./_}}"
    valid_platform "$RELEASE_PLATFORM" || die "Cannot determine target; use --platform with a tested build target."
    [[ "$arch" =~ ^[a-z0-9_]+$ && "$RELEASE_PLATFORM" = *"-$arch" ]] ||
        die "Release target must end with native package architecture: -$arch"
    if [ "$PACKAGE_KIND" = termux ]; then
        [[ "$RELEASE_PLATFORM" = termux-* ]] || die "Termux cannot use a desktop Linux release target."
    else
        [[ "$RELEASE_PLATFORM" != termux-* ]] || die "A Termux target cannot be installed on desktop Linux."
    fi
}
android_api_level() { /system/bin/getprop ro.build.version.sdk; }
detect_platform() {
    local kernel family id like suite ubuntu version arch line text
    kernel="$(uname -s)"
    if is_native_termux; then
        arch="$("$PREFIX/bin/dpkg" --print-architecture)"
        classify_platform "$kernel" termux "" "" "" "" "$arch"
        ANDROID_API="$(android_api_level 2>/dev/null)" ||
            die "Cannot determine Android API level."
        [[ "$ANDROID_API" =~ ^[1-9][0-9]{0,2}$ ]] || die "Invalid Android API level."
        return
    fi
    [ "$kernel" = Linux ] || die "Unsupported operating system: $kernel"
    # An RPM database inside an immutable image does not make dnf safe to use.
    [ ! -e /run/ostree-booted ] || die "OSTree/immutable hosts require their own deployment mechanism."
    local -a os=()
    text="$(
        [ -r /etc/os-release ] || exit 1
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}" "${ID_LIKE:-}" "${VERSION_CODENAME:-}" \
            "${UBUNTU_CODENAME:-}" "${VERSION_ID:-}"
    )" || die "Cannot read /etc/os-release."
    while IFS= read -r line; do os+=("$line"); done <<< "$text"
    id="${os[0]:-unknown}"; like="${os[1]:-}"; suite="${os[2]:-}"
    ubuntu="${os[3]:-}"; version="${os[4]:-}"
    family="$(family_for "$id" "$like")" || die "Unsupported Linux distribution: $id"
    case "$family" in
        deb) require_command dpkg; arch="$(dpkg --print-architecture)" ;;
        arch)
            require_command pacman-conf; arch="$(pacman-conf Architecture)"
            # 'auto' is used by some pacman builds; installed libc gives the
            # userspace architecture even with a different kernel architecture.
            if [ "$arch" = auto ]; then
                arch="$(pacman -Qi glibc | awk -F ': *' '$1 ~ /^Architecture *$/ {print $2}')"
            fi ;;
        rpm|suse) require_command rpm; arch="$(rpm --eval '%{_arch}')" ;;
        apk) require_command apk; arch="$(apk --print-arch)" ;;
    esac
    classify_platform "$kernel" "$id" "$like" "$suite" "$ubuntu" "$version" "$arch"
    if [ "$PACKAGE_MANAGER" = dnf ] && ! command -v dnf >/dev/null 2>&1; then
        if command -v dnf5 >/dev/null 2>&1; then PACKAGE_MANAGER=dnf5
        elif command -v yum >/dev/null 2>&1; then PACKAGE_MANAGER=yum
        else die "DNF/YUM is required for this RPM host."
        fi
    fi
}
need_privileges() {
    if [ "$PACKAGE_KIND" = termux ]; then
        [ "$(id -u)" -ne 0 ] || die "Run Termux installation as the app user, WITHOUT root/sudo."
        [ -d "${PREFIX:-}" ] && [ -w "$PREFIX" ] || die "Termux PREFIX is not writable."
    else
        [ "$(id -u)" -eq 0 ] || die "Run Linux installation with sudo bash install.sh (or as root)."
    fi
}
confirm_install() {
    log "target=$RELEASE_PLATFORM manager=$PACKAGE_MANAGER arch=$PACKAGE_ARCH version=$RELEASE_VERSION"
    if [[ "$PACKAGE_KIND" = arch || "$PACKAGE_KIND" = termux ]]; then
        warn "This backend performs a full package upgrade before installation."
    fi
    [ "$ASSUME_YES" -eq 1 ] && return
    local answer
    if ! { printf 'Install DamageBDD and required runtime packages? [y/N] ' >/dev/tty
           IFS= read -r answer </dev/tty; } 2>/dev/null; then
        die "No interactive terminal. Pass --yes to approve installation."
    fi
    [[ "$answer" = y || "$answer" = Y || "$answer" = yes ]] || die "Installation cancelled."
}
setup_logging() {
    umask 077
    if [ "$PACKAGE_KIND" = termux ]; then LOG_DIR="$PREFIX/var/log/damagebdd"
    else LOG_DIR=/var/log/damagebdd
    fi
    [ ! -L "$LOG_DIR" ] || die "Refusing symlinked log directory."
    if [ "$PACKAGE_KIND" = termux ]; then
        mkdir -p "$LOG_DIR"; chmod 0700 "$LOG_DIR"
    else
        install -d -o root -g root -m 0700 "$LOG_DIR"
    fi
    LOG_FILE="$LOG_DIR/install.log"
    mkdir "$LOG_DIR/.install.lock" 2>/dev/null ||
        die "Another install or stale lock exists: $LOG_DIR/.install.lock"
    LOCK_HELD=1
    [ ! -L "$LOG_FILE" ] && [ ! -L "$LOG_FILE.prev" ] || die "Refusing symlinked log."
    if [ -f "$LOG_FILE" ]; then mv -f "$LOG_FILE" "$LOG_FILE.prev"; fi
    : > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Production installation started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
cleanup() {
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then rm -rf -- "$WORKDIR"; fi
    if [ "$LOCK_HELD" -eq 1 ]; then rmdir "$LOG_DIR/.install.lock" 2>/dev/null || :; fi
}
mkworkdir() {
    local tmp=/tmp
    if [ "$PACKAGE_KIND" = termux ]; then tmp="$PREFIX/tmp"; fi
    [ -d "$tmp" ] && [ -w "$tmp" ] || die "Temporary directory is not writable: $tmp"
    WORKDIR="$(mktemp -d "$tmp/damagebdd-install.XXXXXXXX")"
    chmod 0700 "$WORKDIR"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
# Never pass the installer's pipe to a package manager as interactive stdin.
rolling_upgrade() {
    [ "$ROLLING_UPGRADED" -eq 0 ] || return 0
    case "$PACKAGE_KIND" in
        arch) pacman -Syu --noconfirm </dev/null ;;
        termux) "$PREFIX/bin/pkg" upgrade -y </dev/null ;;
        *) return 0 ;;
    esac
    ROLLING_UPGRADED=1
}
install_tools() {
    case "$PACKAGE_MANAGER" in
        apt-get)
            if [ "$PACKAGE_KIND" = termux ]; then
                rolling_upgrade; "$PREFIX/bin/pkg" install -y "$@" </dev/null
            else
                DEBIAN_FRONTEND=noninteractive apt-get update </dev/null
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" </dev/null
            fi ;;
        pacman) rolling_upgrade; pacman -S --needed --noconfirm "$@" </dev/null ;;
        dnf|dnf5|yum) "$PACKAGE_MANAGER" install -y "$@" </dev/null ;;
        zypper) zypper --non-interactive install --no-recommends "$@" </dev/null ;;
        apk) apk add --no-cache "$@" </dev/null ;;
    esac
}
ensure_download_tools() {
    if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        [ "$CHECK_ONLY" -eq 0 ] || die "--check needs curl and sha256sum installed already."
        install_tools ca-certificates curl coreutils
    fi
    require_command curl; require_command sha256sum
}
ensure_inspection_tools() {
    local -a commands=() packages=()
    case "$PACKAGE_KIND" in
        deb) commands=(dpkg-deb tar); packages=(tar) ;;
        termux) commands=(dpkg-deb tar readelf); packages=(tar binutils) ;;
        arch) commands=(bsdtar); packages=(libarchive) ;;
        rpm) commands=(rpm); packages=(rpm) ;;
        apk) commands=(tar); packages=(tar) ;;
    esac
    local cmd missing=0
    for cmd in "${commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
    # APK v2 is a concatenated tar stream; BusyBox tar lacks --ignore-zeros.
    if [ "$PACKAGE_KIND" = apk ] && ! tar --help 2>&1 | grep -- --ignore-zeros >/dev/null; then missing=1; fi
    if [ "$missing" -eq 1 ]; then
        [ "$CHECK_ONLY" -eq 0 ] || die "--check needs package inspection tools: ${commands[*]}"
        install_tools "${packages[@]}"
    fi
    for cmd in "${commands[@]}"; do require_command "$cmd"; done
}
download() {
    local url="$1" out="$2"
    require_https "$url"
    curl -q --fail --location --silent --show-error \
        --proto '=https' --proto-redir '=https' --max-redirs 4 \
        --connect-timeout 15 --max-time 1800 --retry 3 --output "$out" "$url"
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
    local legacy_url="" legacy_sha="" explicit_url explicit_sha
    case "$PACKAGE_KIND" in
        deb) legacy_url="${DAMAGEBDD_DEB_URL:-}"; legacy_sha="${DAMAGEBDD_DEB_SHA256:-}" ;;
        termux) legacy_url="${DAMAGEBDD_TERMUX_URL:-}"; legacy_sha="${DAMAGEBDD_TERMUX_SHA256:-}"
            [ -z "${DAMAGEBDD_DEB_URL:-}${DAMAGEBDD_DEB_SHA256:-}" ] ||
                die "Use a TERMUX or generic package override, not DAMAGEBDD_DEB_URL in Termux." ;;
        arch) legacy_url="${DAMAGEBDD_ARCH_URL:-}"; legacy_sha="${DAMAGEBDD_ARCH_SHA256:-}" ;;
        rpm) legacy_url="${DAMAGEBDD_RPM_URL:-}"; legacy_sha="${DAMAGEBDD_RPM_SHA256:-}" ;;
        apk) legacy_url="${DAMAGEBDD_APK_URL:-}"; legacy_sha="${DAMAGEBDD_APK_SHA256:-}" ;;
    esac
    if [ -n "${DAMAGEBDD_PACKAGE_URL:-}${DAMAGEBDD_PACKAGE_SHA256:-}" ]; then
        [ -z "$legacy_url$legacy_sha" ] || die "Do not mix generic and backend-specific package overrides."
        explicit_url="${DAMAGEBDD_PACKAGE_URL:-}"; explicit_sha="${DAMAGEBDD_PACKAGE_SHA256:-}"
    else explicit_url="$legacy_url"; explicit_sha="$legacy_sha"
    fi
    if [ -n "$explicit_url" ]; then
        [[ "$explicit_sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "Explicit URL requires its SHA-256."
        require_https "$explicit_url"
        warn "Explicit package URL selected; NFT discovery is bypassed."
        ARTIFACT_URL="$explicit_url"; ARTIFACT_SHA256="${explicit_sha,,}"
        return
    fi
    [ -z "$explicit_sha" ] || die "Checksum supplied without a package URL."
    require_https "$RELEASE_API"; require_https "$IPFS_GATEWAY"
    local manifest="$WORKDIR/release.txt"
    curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 15 --max-time 60 --retry 2 --max-filesize 8192 \
        --get --data-urlencode "platform=$RELEASE_PLATFORM" --data-urlencode 'format=install' \
        --output "$manifest" "${RELEASE_API%/}/$RELEASE_VERSION" ||
        die "Release discovery failed for $RELEASE_PLATFORM. Publish a compatible build; no fallback was selected."
    parse_install_manifest "$manifest"
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
    ' "$TOR_SOURCE" > "$WORKDIR/tor.sources.package-keyring" || die "Cannot prepare Tor keyring source update."
    install -o root -g root -m 0644 "$WORKDIR/tor.sources.package-keyring" "$TOR_SOURCE" ||
        die "Cannot switch Tor source to its package-maintained keyring."
    rm -f "$TOR_KEYRING"
}
try_torproject_debian() {
    [[ "$PACKAGE_ARCH" = amd64 || "$PACKAGE_ARCH" = arm64 ]] || return 1
    [[ "$BASE_SUITE" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    if [ -e "$TOR_SOURCE" ] || [ -L "$TOR_SOURCE" ] || [ -e "$TOR_KEYRING" ] || [ -L "$TOR_KEYRING" ]; then
        # A previous/admin-managed file is not ours to overwrite or delete.
        warn "Tor source/keyring already exists; preserving configured APT sources."
        return 1
    fi
    curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 10 --max-time 30 --output /dev/null \
        "$TOR_REPO/dists/$BASE_SUITE/InRelease" || return 1
    require_command gpg
    local asc="$WORKDIR/tor.asc" key="$WORKDIR/tor.gpg" fingerprint keyinfo="$WORKDIR/tor.keyinfo"
    download "$TOR_KEY_URL" "$asc" || return 1
    mkdir -p "$WORKDIR/gnupg" || return 1
    chmod 0700 "$WORKDIR/gnupg" || return 1
    gpg --homedir "$WORKDIR/gnupg" --batch --show-keys --with-colons "$asc" > "$keyinfo" 2>/dev/null || return 1
    [ "$(awk -F: '$1=="pub" {n++} END {print n+0}' "$keyinfo")" = 1 ] ||
        die "Tor signing-key download must contain exactly one primary key."
    fingerprint="$(awk -F: '$1=="fpr" && !found {print $10; found=1}' "$keyinfo")" || return 1
    [ "$fingerprint" = "$TOR_KEY_FPR" ] || die "Tor signing-key fingerprint mismatch."
    gpg --homedir "$WORKDIR/gnupg" --batch --yes --dearmor --output "$key" "$asc" || return 1
    install -d -o root -g root -m 0755 /etc/apt/keyrings || return 1
    install -o root -g root -m 0644 "$key" "$TOR_KEYRING" || return 1
    cat > "$WORKDIR/tor.sources.new" <<TOR
Types: deb
URIs: $TOR_REPO
Suites: $BASE_SUITE
Components: main
Architectures: $PACKAGE_ARCH
Signed-By: $TOR_KEYRING
TOR
    install -o root -g root -m 0644 "$WORKDIR/tor.sources.new" "$TOR_SOURCE" || die "Cannot write Tor source."
    if DEBIAN_FRONTEND=noninteractive apt-get update </dev/null &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tor deb.torproject.org-keyring </dev/null; then
        use_packaged_tor_keyring
        log "Tor installed with the Tor Project repository configured."
        return 0
    fi
    warn "Tor Project installation failed; removing only the files created by this run."
    rm -f "$TOR_SOURCE" "$TOR_KEYRING"
    return 1
}
ensure_tor_debian() {
    if tor_deb_installed || command -v tor >/dev/null 2>&1; then
        log "Existing Tor installation preserved (package dependencies still apply)."; return
    fi
    if [[ "$TOR_POLICY" = auto || "$TOR_POLICY" = official ]] && [ -n "$BASE_SUITE" ]; then
        if ! command -v gpg >/dev/null 2>&1; then install_tools gnupg; fi
        if try_torproject_debian; then return; fi
    fi
    [ "$TOR_POLICY" != official ] || die "Cannot configure official Tor APT source for this host."
    warn "Installing Tor from the administrator's configured distribution sources."
    install_tools tor
}
ensure_tor() {
    [ "$TOR_POLICY" != skip ] || return 0
    if [ "$PACKAGE_KIND" = deb ]; then ensure_tor_debian; return; fi
    if command -v tor >/dev/null 2>&1; then log "Existing Tor preserved."; return; fi
    [ "$TOR_POLICY" != official ] || die "Automatic official Tor source setup is APT-only. Use --tor system here."
    # Never silently enable EPEL, COPR, or other repositories. The operator's
    # package repositories must provide tor and the package's other dependencies.
    log "Installing Tor through $PACKAGE_MANAGER from configured repositories."
    install_tools tor
}


# All validators run only AFTER SHA-256 verification, and never execute payloads.
has_bundled_erts() {
    awk '/(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {found=1} END {exit !found}'
}
validate_deb_package() {
    local package="$1" name arch
    name="$(dpkg-deb -f "$package" Package)"; arch="$(dpkg-deb -f "$package" Architecture)"
    PACKAGE_VERSION="$(dpkg-deb -f "$package" Version)"
    [ "$name" = damage ] || die "Downloaded DEB is not the damage package."
    [ "$arch" = "$PACKAGE_ARCH" ] || die "DEB architecture mismatch."
    dpkg-deb --fsys-tarfile "$package" | tar -tf - > "$WORKDIR/payload.list"
    has_bundled_erts < "$WORKDIR/payload.list" || die "Release DEB is missing bundled ERTS."
    if [ "$PACKAGE_KIND" = deb ] && grep -Eq '^\.?/?data/(data|user)/' "$WORKDIR/payload.list"; then
        die "Termux payload cannot be installed as a desktop Debian package."
    fi
}
validate_termux_paths() {
    local listing="$1" member path parent="${PREFIX#/}" allowed
    while IFS= read -r member; do
        path="${member#./}"; path="${path%/}"
        if [ -z "$path" ] || [ "$path" = . ]; then continue; fi
        [[ "$path" != /* && "$path" != *'\'* && "/$path/" != */../* && "/$path/" != */./* ]] ||
            die "Unsafe path in Termux package."
        if [[ "$path" = "$parent/"* || "$path" = "$parent" ]]; then continue; fi
        # Ancestor directories are normal in Termux .deb archives; no outside files.
        allowed=0
        if [[ "$member" = */ && "$parent/" = "$path/"* ]]; then allowed=1; fi
        [ "$allowed" -eq 1 ] || die "Termux package payload escapes PREFIX: $path"
    done < "$listing"
}
validate_termux_package() {
    local package="$1" target prefix min_api beam_member interpreter header expected
    validate_deb_package "$package"
    target="$(dpkg-deb -f "$package" X-Damage-Target)"
    prefix="$(dpkg-deb -f "$package" X-Termux-Prefix)"
    min_api="$(dpkg-deb -f "$package" X-Android-Min-API)"
    [ "$target" = "$RELEASE_PLATFORM" ] || die "Termux package needs matching X-Damage-Target."
    [ "$prefix" = "$PREFIX" ] || die "Termux package was built for a different or unspecified PREFIX."
    [[ "$min_api" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$min_api" -le "$ANDROID_API" ] ||
        die "Termux package requires a missing or newer Android API level."
    validate_termux_paths "$WORKDIR/payload.list"
    beam_member="$(awk '/(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {print}' "$WORKDIR/payload.list")"
    [[ -n "$beam_member" && "$beam_member" != *$'\n'* ]] || die "Expected exactly one bundled ERTS executable."
    dpkg-deb --fsys-tarfile "$package" | tar -xOf - "$beam_member" > "$WORKDIR/beam.inspect"
    # Inspect ELF; do not invoke the downloaded binary or ldd.
    header="$(readelf -h "$WORKDIR/beam.inspect")" || die "Bundled ERTS is not a readable ELF binary."
    interpreter="$(readelf -l "$WORKDIR/beam.inspect")" || die "Cannot inspect ERTS interpreter."
    case "$PACKAGE_ARCH" in
        aarch64) expected='AArch64'; [[ "$header" = *'ELF64'* ]] || die "Expected 64-bit ERTS." ;;
        x86_64) expected='Advanced Micro Devices X86-64'; [[ "$header" = *'ELF64'* ]] || die "Expected 64-bit ERTS." ;;
        arm) expected='ARM'; [[ "$header" = *'ELF32'* ]] || die "Expected 32-bit ERTS." ;;
        i686) expected='Intel 80386'; [[ "$header" = *'ELF32'* ]] || die "Expected 32-bit ERTS." ;;
    esac
    [[ "$header" = *"Machine:"*"$expected"* ]] || die "Termux ERTS ELF machine mismatch."
    case "$PACKAGE_ARCH" in aarch64|x86_64) expected=/system/bin/linker64 ;; *) expected=/system/bin/linker ;; esac
    [[ "$interpreter" = *"Requesting program interpreter: $expected]"* ]] ||
        die "Bundled ERTS is not Android/Bionic-linked; desktop Linux packages do not work in native Termux."
    # The package, not this bootstrap, owns config, native dependencies and runit.
    awk -v p="${PREFIX#/}/bin/damage" '{sub(/^\.\//, ""); if ($0==p) f=1} END{exit !f}' \
        "$WORKDIR/payload.list" || die "Termux package must provide PREFIX/bin/damage."
    awk -v p="${PREFIX#/}/var/service/damage/run" '{sub(/^\.\//, ""); if ($0==p) f=1} END{exit !f}' \
        "$WORKDIR/payload.list" || die "Termux package must provide its runit service."
}
validate_arch_package() {
    local info name arch
    info="$(bsdtar -xOf "$1" .PKGINFO)"
    name="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="pkgname" {print $2}')"
    arch="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="arch" {print $2}')"
    PACKAGE_VERSION="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="pkgver" {print $2}')"
    [ "$name" = damage ] && [ "$arch" = "$PACKAGE_ARCH" ] || die "Arch package name/architecture mismatch."
    bsdtar -tf "$1" | has_bundled_erts || die "Arch release is missing bundled ERTS."
}
validate_rpm_package() {
    local name arch
    name="$(rpm -qp --queryformat '%{NAME}' "$1")"; arch="$(rpm -qp --queryformat '%{ARCH}' "$1")"
    PACKAGE_VERSION="$(rpm -qp --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$1")"
    [ "$name" = damage ] && [ "$arch" = "$PACKAGE_ARCH" ] || die "RPM name/architecture mismatch."
    rpm -qpl "$1" | has_bundled_erts || die "RPM release is missing bundled ERTS."
}
validate_apk_package() {
    local info name arch
    # Do not use --allow-untrusted. The publisher's APK signing key must already
    # be trusted in /etc/apk/keys. The SHA-256 check is an additional check.
    apk verify "$1" || die "APK signature is not trusted or the archive is corrupt."
    info="$(tar --ignore-zeros -xOzf "$1" .PKGINFO)" ||
        die "This inspector requires a format-v2 Alpine APK (.PKGINFO); v3 is not yet handled."
    name="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="pkgname" {print $2}')"
    arch="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="arch" {print $2}')"
    PACKAGE_VERSION="$(printf '%s\n' "$info" | awk -F ' = ' '$1=="pkgver" {print $2}')"
    [ "$name" = damage ] && [ "$arch" = "$PACKAGE_ARCH" ] || die "APK name/architecture mismatch."
    tar --ignore-zeros -tzf "$1" | has_bundled_erts || die "Alpine release is missing bundled ERTS."
}
validate_package() {
    case "$PACKAGE_KIND" in
        deb) validate_deb_package "$1" ;;
        termux) validate_termux_package "$1" ;;
        arch) validate_arch_package "$1" ;;
        rpm) validate_rpm_package "$1" ;;
        apk) validate_apk_package "$1" ;;
    esac
    [ -n "$PACKAGE_VERSION" ] || die "Downloaded package has no version."
}
install_native_package() {
    case "$PACKAGE_MANAGER" in
        apt-get)
            if [ "$PACKAGE_KIND" = termux ]; then
                DEBIAN_FRONTEND=noninteractive "$PREFIX/bin/apt-get" install -y --no-install-recommends "$1" </dev/null
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$1" </dev/null
            fi ;;
        pacman) pacman -U --needed --noconfirm "$1" </dev/null ;;
        dnf|dnf5|yum) "$PACKAGE_MANAGER" install -y "$1" </dev/null ;;
        zypper) zypper --non-interactive install --no-recommends "$1" </dev/null ;;
        apk) apk add --no-cache "$1" </dev/null ;;
    esac
    # Package managers can return success without changing an already-newer
    # package. Never claim that the selected release was installed in that case.
    local installed
    case "$PACKAGE_KIND" in
        deb) installed="$(dpkg-query -W -f='${Version}' damage)" ;;
        termux) installed="$("$PREFIX/bin/dpkg-query" -W -f='${Version}' damage)" ;;
        arch) installed="$(pacman -Q damage)"; installed="${installed#damage }" ;;
        rpm) installed="$(rpm -q --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' damage)" ;;
        apk) installed="$(apk info -v damage)"; installed="${installed#damage-}" ;;
    esac
    [ "$installed" = "$PACKAGE_VERSION" ] ||
        die "Installed version differs from selected package. Manage downgrades explicitly with your package manager."
}
install_release() {
    local package suffix
    ensure_download_tools
    resolve_package
    case "$PACKAGE_KIND" in
        deb|termux) suffix=deb ;; arch) suffix=pkg.tar.zst ;; rpm) suffix=rpm ;; apk) suffix=apk ;;
    esac
    package="$WORKDIR/damage.$suffix"
    download "$ARTIFACT_URL" "$package"
    verify_sha256 "$package" "$ARTIFACT_SHA256"
    ensure_inspection_tools
    validate_package "$package"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        log "Validation passed for $RELEASE_PLATFORM, package version $PACKAGE_VERSION; nothing installed."
        return
    fi
    rolling_upgrade
    if [ "$PACKAGE_KIND" = termux ]; then install_tools termux-services; fi
    ensure_tor
    install_native_package "$package"
}
wait_termux_supervisor() {
    local attempts=0
    while [ ! -p "$SVDIR/damage/supervise/ok" ] && [ "$attempts" -lt 100 ]; do
        sleep 0.1; attempts=$((attempts + 1))
    done
    [ -p "$SVDIR/damage/supervise/ok" ] || die "runit did not discover the Damage service. Restart the Termux shell and retry."
}
start_package_service() {
    [ "$START_SERVICE" -eq 1 ] || return 0
    if [ "$PACKAGE_KIND" = termux ]; then
        export SVDIR="$PREFIX/var/service" LOGDIR="$PREFIX/var/log"
        require_command service-daemon; require_command sv-enable; require_command sv
        [ -x "$SVDIR/damage/run" ] || die "Package-provided Termux service is missing."
        # A previously-running supervisor can make service-daemon return nonzero;
        # sv up below is the authoritative check, and its failure is NOT ignored.
        if ! service-daemon start; then log "Checking whether runit is already supervising services."; fi
        wait_termux_supervisor
        sv-enable damage
        sv -w 30 up "$SVDIR/damage"
    elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now damage.service
    elif command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/damage ]; then
        rc-update add damage default
        rc-service damage start
    else
        die "Package installed, but --start found no supported package-provided service."
    fi
}
post_install() {
    log "Damage package $PACKAGE_VERSION installed for $RELEASE_PLATFORM."
    log "Configuration, credentials, native dependencies and onion provisioning remain package-managed."
    start_package_service
    local hostname_file=/var/lib/damage/tor/hostname onion
    if [ "$PACKAGE_KIND" = termux ]; then
        hostname_file="$PREFIX/var/lib/damage/tor/hostname"
        log "Termux service: start a new shell, then run sv-enable damage."
        log "Android background-process limits may stop services; this installer cannot guarantee phone uptime."
    fi
    if [ -r "$hostname_file" ]; then
        onion="$(tr -d '\r\n' < "$hostname_file")"
        if [[ "$onion" =~ ^[a-z2-7]{56}\.onion$ ]]; then log "Onion address: http://$onion/"; fi
    fi
    if [ -n "$HEALTH_URL" ]; then
        if curl -q --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
            "$HEALTH_URL" >/dev/null; then log "Local version endpoint responded."
        else warn "Package installed; version endpoint is not responding yet. Check configuration/unlock and service logs."
        fi
    fi
    log "Install log: $LOG_FILE"
}
main() {
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "Bash 4 or newer is required."
    parse_options "$@"
    detect_platform
    if [ "$PRINT_PLATFORM" -eq 1 ]; then printf '%s\n' "$RELEASE_PLATFORM"; return; fi
    # Only a local loopback health URL is meaningful; don't send an arbitrary
    # redirect or inherit proxy settings for localhost checks.
    [[ -z "$HEALTH_URL" || "$HEALTH_URL" =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/[^[:space:]]*$ ]] ||
        die "DAMAGEBDD_HEALTH_URL must be an HTTP loopback URL (or empty)."
    if [ "$CHECK_ONLY" -eq 0 ]; then need_privileges; confirm_install; fi
    mkworkdir
    if [ "$CHECK_ONLY" -eq 0 ]; then setup_logging; fi
    trap 'log "Operation failed at line $LINENO; installation did not complete."' ERR
    install_release
    if [ "$CHECK_ONLY" -eq 0 ]; then post_install; fi
}
# Sourceable for offline tests. A piped bash has no BASH_SOURCE.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" = "$0" ]]; then main "$@"; fi
