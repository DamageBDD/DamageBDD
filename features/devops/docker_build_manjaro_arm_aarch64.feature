# Manjaro ARM aarch64 installer platform. Requires a working linux/arm64 Docker
# runner and the pinned ARM builder Dockerfile CID below. This builder uses an
# Arch Linux ARM userspace: validate runtime dependencies on Manjaro ARM before
# publishing a production release; the platform key alone is not compatibility.
# PACMAN_DISABLE_SANDBOX=1 is for the QEMU/Landlock-limited build host only.
Feature: Publish DamageBDD for Manjaro ARM aarch64
  Scenario: Build and verify the manjaro-arm-aarch64 installation release
    Given the build release discovery is configured
    When I build an image from Dockerfile at "Qme2zQxE18bXrzNYE6zJYAY7kH8vC9myCHzbcDvnHbqRSR" as tag "damagebdd/manjaro-arm-builder:aarch64-v2" with params "--platform linux/arm64 --build-arg 'PACMAN_DISABLE_SANDBOX=1' --build-arg 'REPO_URL=https://github.com/DamageBDD/DamageBDD.git' --build-arg 'REPO_REF=develop'"
    Then I run docker image tagged "damagebdd/manjaro-arm-builder:aarch64-v2"
    """
    set -eux
    cd /opt/workspace

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
    damage-builder-check
    pkg-config --print-errors --exists gtk4 shumate-1.0 liboqs

    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            echo "This feature must execute as linux/arm64/aarch64; got $(uname -m)" >&2
            echo "Use a native ARM64 runner or configure Docker binfmt/QEMU for linux/arm64." >&2
            exit 1
            ;;
    esac

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

    LISTING=$(tar -tf "$PACKAGE")
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

    NFT_DIR="$PWD/nft"
    mkdir -p "$NFT_DIR"
    install -m 0644 "$PACKAGE" "$NFT_DIR/damage.pkg.tar.zst"
    cp PKGBUILD "$NFT_DIR/PKGBUILD"
    makepkg --printsrcinfo > "$NFT_DIR/.SRCINFO"

    printf '%s\n' "$GIT_SHA" > "$NFT_DIR/GIT_COMMIT"
    printf '%s\n' "$RELEASE_VSN" > "$NFT_DIR/RELEASE_VERSION"
    git -C /opt/workspace describe --tags --always --dirty > "$NFT_DIR/GIT_DESCRIBE"
    (
        cd "$NFT_DIR"
        sha256sum damage.pkg.tar.zst > SHA256SUMS
        DIGEST=$(awk '{print $1}' SHA256SUMS)
        cat > installation.json <<JSON
    {
      "schema_version": 1,
      "release": "$RELEASE_VSN",
      "platform": "manjaro-arm-aarch64",
      "package_format": "pkg.tar.zst",
      "architecture": "aarch64",
      "asset_path": "damage.pkg.tar.zst",
      "sha256": "$DIGEST",
      "git_sha": "$GIT_SHA"
    }
    JSON
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
