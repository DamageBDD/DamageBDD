# DamageBDD release contract for PinePhone Pro / Manjaro ARM stable:
# - target platform: manjaro-arm-aarch64
# - target runtime: glibc <= 2.41, OTP 28, ERTS 16.x, AArch64
# - Dockerfile is versioned separately at packaging/manjaro-arm/Dockerfile
# - Upload Dockerfile with `ipfs add -Q packaging/manjaro-arm/Dockerfile`
#   and replace __MANJARO_ARM_DOCKERFILE_CID__ before submitting.
# - The checkout at REPO_REF must include check-package-abi.sh and the
#   canonical systemd unit packaging fix before this feature can pass.
# - PACMAN_DISABLE_SANDBOX=1 is for the QEMU/Landlock-limited build host.
Feature: Publish DamageBDD for Manjaro ARM aarch64
  Scenario: Build and verify the manjaro-arm-aarch64 installation release
    Given the build release discovery is configured
    When I build an image from Dockerfile at "QmUYGfQHv837GQnbLXjyUpANbFFTNQEBbWEkBh4h7YYkuY" as tag "damagebdd/manjaro-arm-builder:otp28-glibc241" with params "--platform linux/arm64 --build-arg 'PACMAN_DISABLE_SANDBOX=1' --build-arg 'TARGET_GLIBC=2.41' --build-arg 'TARGET_OTP_MAJOR=28' --build-arg 'TARGET_ERTS_MAJOR=16' --build-arg 'REPO_URL=https://github.com/DamageBDD/DamageBDD.git' --build-arg 'REPO_REF=develop'"
    Then I run docker image tagged "damagebdd/manjaro-arm-builder:otp28-glibc241"
    """
    set -eux
    cd /opt/workspace

    # Some builder layers leave $HOME/.cache unwritable by the damage user.
    # Move disposable caches only; retain HOME and the voice SDK install prefixes.
    # This private cache stays with this container, outside the checkout/package.
    [ "$(id -u)" -ne 0 ] || {
        echo "[damagebdd] Refusing a root release build; use the damage user." >&2
        exit 1
    }
    XDG_CACHE_HOME=$(mktemp -d /tmp/damagebdd-build-cache.XXXXXXXX)
    CCACHE_DIR="$XDG_CACHE_HOME/ccache"
    export XDG_CACHE_HOME CCACHE_DIR
    mkdir -p "$CCACHE_DIR" "$XDG_CACHE_HOME/erm-native-voice"
    for CACHE_PATH in "$XDG_CACHE_HOME" "$CCACHE_DIR" "$XDG_CACHE_HOME/erm-native-voice"; do
        CACHE_PROBE=$(mktemp "$CACHE_PATH/.write-check.XXXXXXXX")
        rm -f "$CACHE_PROBE"
    done
    printf '%s\n' "[damagebdd] writable build cache: $XDG_CACHE_HOME"

    command -v flock >/dev/null 2>&1 || {
        echo "Builder requires flock (util-linux)" >&2
        exit 1
    }
    LOCK_FILE=$(git rev-parse --git-path damage-build.lock)
    exec 9>>"$LOCK_FILE"
    flock -n 9 || {
        echo "Another build holds the workspace lock; refusing to clean _build" >&2
        exit 1
    }
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
        git fetch --unshallow --tags
    else
        git fetch --tags
    fi
    git pull --ff-only
    git diff --exit-code HEAD -- .
    sh bin/check-beam-sources.sh
    # Fail before spending time compiling an OTP release if native libs are missing.
    command -v erl >/dev/null 2>&1
    command -v rebar3 >/dev/null 2>&1
    command -v makepkg >/dev/null 2>&1
    pkg-config --print-errors --exists gtk4 shumate-1.0 liboqs

    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            echo "This feature must execute as linux/arm64/aarch64; got $(uname -m)" >&2
            echo "Use a native ARM64 runner or configure Docker binfmt/QEMU for linux/arm64." >&2
            exit 1
            ;;
    esac

    # A documented Manjaro ARM stable ABI is mandatory, not merely an ARM64
    # package label. Ensure the running builder and compiler use OTP 28 and a
    # userspace no newer than the device before invoking rebar3.
    test -f /etc/os-release
    grep -Eiq '(^ID=.*manjaro|^ID_LIKE=.*manjaro|^NAME=.*manjaro)' /etc/os-release || {
        echo "ERROR: release builder is not Manjaro ARM" >&2; exit 1
    }
    BUILDER_GLIBC=$(getconf GNU_LIBC_VERSION | awk '{print $2}')
    [ "$(printf '%s\n%s\n' "$BUILDER_GLIBC" 2.41 | sort -V | tail -n 1)" = 2.41 ] || {
        echo "ERROR: builder glibc $BUILDER_GLIBC exceeds target glibc 2.41" >&2
        exit 1
    }
    BUILDER_OTP=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
    BUILDER_ERTS=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(version)]), halt().')
    [ "$BUILDER_OTP" = 28 ] || { echo "ERROR: expected OTP 28, got $BUILDER_OTP" >&2; exit 1; }
    case "$BUILDER_ERTS" in
        16.*) ;;
        *) echo "ERROR: expected ERTS 16.x, got $BUILDER_ERTS" >&2; exit 1 ;;
    esac
    test -f packaging/manjaro-arm/check-package-abi.sh || {
        echo "ERROR: missing Manjaro package ABI gate; commit it to develop first" >&2
        exit 1
    }
    echo "[damagebdd] Manjaro ARM ABI builder: glibc=$BUILDER_GLIBC OTP=$BUILDER_OTP ERTS=$BUILDER_ERTS"

    # Preserve the dependency set committed with this checkout.
    test -f rebar.lock
    git diff --exit-code HEAD -- rebar.lock
    GIT_SHA=$(git rev-parse HEAD)
    rm -rf _build
    rebar3 as prod release
    git diff --exit-code HEAD -- rebar.lock

    # Read the actual assembled OTP release. Because include_erts=true, this
    # release is architecture-specific and must be packaged on/for aarch64.
    RELEASE_VSN=$(erl -noshell -eval '
        case filelib:wildcard("_build/*/rel/damage/releases/*/damage.rel") of
            [Path] ->
                {ok, [{release, {"damage", Vsn}, _, _}]} = file:consult(Path),
                io:format("~s", [Vsn]), halt(0);
            _ -> halt(1)
        end.')
    case "$RELEASE_VSN" in
        ''|*[!A-Za-z0-9._+-]*) echo "Invalid OTP release version" >&2; exit 1 ;;
    esac
    case "$RELEASE_VSN" in
        [A-Za-z0-9]*) ;;
        *) echo "Invalid OTP release version prefix" >&2; exit 1 ;;
    esac
    if [ "${#RELEASE_VSN}" -gt 160 ] || [ "$RELEASE_VSN" = latest ]; then
        echo "Invalid or reserved OTP release version" >&2
        exit 1
    fi

    rebar3 as prod pkg gen -t arch --fpm=false
    git diff --exit-code HEAD -- rebar.lock
    cd _build/pkg/arch/damage

    # rebar3_pkg may generate a host/default arch value. This package contains
    # native ERTS/NIFs, so force the generated PKGBUILD to the real target.
    sed -Ei "s/^arch=.*/arch=('aarch64')/" PKGBUILD
    grep -Fx "arch=('aarch64')" PKGBUILD
    makepkg

    # Select only the main DamageBDD package and reject mislabeled builds.
    PACKAGE=''
    for CANDIDATE in ./*.pkg.tar.zst; do
        [ -f "$CANDIDATE" ] || continue
        PKGINFO=$(tar -xOf "$CANDIDATE" .PKGINFO)
        NAME=$(printf '%s\n' "$PKGINFO" | awk '$1 == "pkgname" && $2 == "=" {print $3}')
        [ "$NAME" = damage ] || continue
        [ -z "$PACKAGE" ] || { echo "Multiple damage packages found" >&2; exit 1; }
        ARCH=$(printf '%s\n' "$PKGINFO" | awk '$1 == "arch" && $2 == "=" {print $3}')
        [ "$ARCH" = aarch64 ] || { echo "Wrong package architecture: $ARCH" >&2; exit 1; }
        PACKAGE=$CANDIDATE
    done
    [ -n "$PACKAGE" ] || { echo "No aarch64 damage package found" >&2; exit 1; }

    # Release integrity gate: a package that cannot install its systemd unit
    # must never be uploaded to IPFS or minted as an installable release.
    # Package-owned vendor units belong under /usr/lib, not /etc overrides.
    LISTING=$(tar -tf "$PACKAGE")
    UNIT_PATH=$(printf '%s\n' "$LISTING" | awk '
        /^\.?\/?usr\/lib\/systemd\/system\/damage\.service$/ { print }
    ')
    [ "$(printf '%s\n' "$UNIT_PATH" | sed '/^$/d' | wc -l)" -eq 1 ] || {
        echo "Missing or duplicated vendor systemd unit in package: usr/lib/systemd/system/damage.service" >&2
        exit 1
    }
    UNIT_SOURCE=/opt/workspace/apps/damage/priv/pkg/damage.service
    [ -s "$UNIT_SOURCE" ] || {
        echo "Canonical repository unit missing: $UNIT_SOURCE" >&2
        exit 1
    }
    tar -xOf "$PACKAGE" "$UNIT_PATH" | cmp - "$UNIT_SOURCE" || {
        echo "Packaged systemd unit differs from the canonical source" >&2
        exit 1
    }
    echo "[damagebdd] Verified vendor systemd unit: $UNIT_PATH"
    if printf '%s\n' "$LISTING" | grep -Eq '^\.?/?etc/systemd/system/damage\.service$'; then
        echo "Package must not install a unit into the administrator override directory /etc/systemd/system" >&2
        exit 1
    fi

    # 20-systemd.sh is executed by package installation. Verify the old
    # hard-coded /etc unit requirement is absent before publication.
    HOOK_PATH=$(printf '%s\n' "$LISTING" | awk '
        /^\.?\/?opt\/damage\/postinst\.d\/20-systemd\.sh$/ { print }
    ')
    [ "$(printf '%s\n' "$HOOK_PATH" | sed '/^$/d' | wc -l)" -eq 1 ] || {
        echo "Missing or duplicated post-install systemd hook in package" >&2
        exit 1
    }
    if tar -xOf "$PACKAGE" "$HOOK_PATH" | grep -Fq '/etc/systemd/system/damage.service'; then
        echo "Post-install hook still requires /etc/systemd/system/damage.service" >&2
        echo "Update 20-systemd.sh to use the packaged vendor unit in /usr/lib/systemd/system." >&2
        exit 1
    fi

    BEAM_PATH=$(printf '%s\n' "$LISTING" | awk '/(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {print; exit}')
    [ -n "$BEAM_PATH" ] || {
        echo "Production package does not contain bundled ERTS" >&2
        exit 1
    }

    # Verify the bundled VM is really AArch64, not merely relabeled metadata.
    TMP_BEAM=$(mktemp)
    trap 'rm -f "$TMP_BEAM"' EXIT
    tar -xOf "$PACKAGE" "$BEAM_PATH" > "$TMP_BEAM"
    readelf -h "$TMP_BEAM" | grep -Eq 'Machine:[[:space:]]+AArch64' || {
        echo "Bundled beam.smp is not AArch64" >&2
        exit 1
    }

    # Check every installed ELF, not only the launcher (which is a shell script).
    # This rejects bundled beam.smp 17.1 / GLIBC_2.43, incompatible NIFs,
    # foreign-architecture objects and missing/incorrect bundled ERTS.
    sh /opt/workspace/packaging/manjaro-arm/check-package-abi.sh "$PACKAGE" 2.41 16

    NFT_DIR="$PWD/nft"
    mkdir -p "$NFT_DIR"
    install -m 0644 "$PACKAGE" "$NFT_DIR/damage.pkg.tar.zst"
    cp PKGBUILD "$NFT_DIR/PKGBUILD"
    # PKGBUILD references this SHA-256-verified local source; retain it so
    # the published build recipe remains reproducible from the NFT payload.
    test -s damage.service
    cmp damage.service /opt/workspace/apps/damage/priv/pkg/damage.service
    cp damage.service "$NFT_DIR/damage.service"
    makepkg --printsrcinfo > "$NFT_DIR/.SRCINFO"

    # Use printf, not shell heredocs. The Gherkin placeholder parser treats
    # angle-delimited heredoc syntax as a step-variable candidate.
    printf '%s\n' \
        'platform=manjaro-arm-aarch64' \
        'builder=manjaro-arm-stable' \
        'glibc_abi_ceiling=2.41' \
        'otp_major=28' \
        'erts_major=16' \
        "actual_builder_glibc=$BUILDER_GLIBC" \
        "actual_builder_otp=$BUILDER_OTP" \
        "actual_builder_erts=$BUILDER_ERTS" \
        'ELF_gate=passed' > "$NFT_DIR/ABI_COMPATIBILITY"

    printf '%s\n' "$GIT_SHA" > "$NFT_DIR/GIT_COMMIT"
    printf '%s\n' "$RELEASE_VSN" > "$NFT_DIR/RELEASE_VERSION"
    git -C /opt/workspace describe --tags --always --dirty > "$NFT_DIR/GIT_DESCRIBE"
    (
        cd "$NFT_DIR"
        sha256sum damage.pkg.tar.zst > SHA256SUMS
        DIGEST=$(awk '{print $1}' SHA256SUMS)
        printf '%s\n' \
            '{' \
            '  "schema_version": 1,' \
            "  \"release\": \"$RELEASE_VSN\"," \
            '  "platform": "manjaro-arm-aarch64",' \
            '  "package_format": "pkg.tar.zst",' \
            '  "architecture": "aarch64",' \
            '  "glibc_abi_ceiling": "2.41",' \
            '  "otp_major": 28,' \
            '  "erts_major": 16,' \
            '  "build_distribution": "manjaro-arm-stable",' \
            '  "asset_path": "damage.pkg.tar.zst",' \
            "  \"sha256\": \"$DIGEST\"," \
            "  \"git_sha\": \"$GIT_SHA\"" \
            '}' > installation.json
    )
    find "$NFT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
    """
    Then I copy file "/opt/workspace/_build/pkg/arch/damage/nft/" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "DamageBDD Manjaro ARM Software Package",
      "description": "Production aarch64 package with bundled ERTS, Git SHA, package SHA-256 and installation path bound through the build release NFT metadata CID.",
      "project": "DamageBDD",
      "platform": "manjaro-arm-aarch64",
      "package_path": "damage.pkg.tar.zst",
      "artifact_type": "arch_package",
      "package_format": "pkg.tar.zst",
      "architecture": "aarch64",
      "glibc_abi_ceiling": "2.41",
      "otp_major": 28,
      "erts_major": 16,
      "build_distribution": "manjaro-arm-stable",
      "build_system": "docker + rebar3 + makepkg",
      "build_profile": "prod",
      "ci_intent": "release",
      "network": "aeternity",
      "license": "Apache-2.0",
      "tags": [
        "damagebdd",
        "bdd",
        "ci",
        "arm64",
        "aarch64",
        "manjaro-arm",
        "supply-chain",
        "verifiable-artifacts"
      ]
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    When I prepare installation metadata in "meta" for platform "manjaro-arm-aarch64" from IPFS asset hash in "asset_hash" with manifest path "installation.json"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"

    When I mint build release "{{build_release}}" for platform "manjaro-arm-aarch64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    Then the latest installable build release must match the minted NFT
