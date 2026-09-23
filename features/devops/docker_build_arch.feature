# Installation builds and the serving API must share ae_network_id and
# build_release_nft_contract. See docs/release-discovery.md.
Feature: Publish an installable Arch Linux release
  Scenario: Build and verify the archlinux-x86_64 installation release
    Given the build release discovery is configured
    When I build an image from Dockerfile at "Qmf7VT78ku7beFFwAVib5zk71iPJ4VH7NAxa7rWbwXrWkT" as tag "damagebdd/arch-builder:latest" with params "--build-arg 'REPO_URL=https://github.com/DamageBDD/DamageBDD.git' --build-arg 'REPO_REF=develop'"
    Then I run docker image tagged "damagebdd/arch-builder:latest"
    """
    set -eux
    export CUDA_LIB64=/opt/cuda/lib64/
    export PATH="$PATH:/opt/cuda/bin/"
    cd /opt/workspace

    # Serialize the workspace before fetching, cleaning, building or staging.
    # The lock lives outside _build and is never removed by cleanup.
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

    [ "$(uname -m)" = x86_64 ] || {
        echo "This feature publishes only archlinux-x86_64" >&2
        exit 1
    }

    # Preserve the dependency set committed with this checkout.
    test -f rebar.lock
    git diff --exit-code HEAD -- rebar.lock
    GIT_SHA=$(git rev-parse HEAD)
    rm -rf _build
    rebar3 as prod release
    git diff --exit-code HEAD -- rebar.lock

    # Read the actual assembled OTP release, not git describe or an asset CID.
    # Exactly one release must exist in this clean build; no guess at a version.
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
    makepkg

    # Select only the damage package; a separately generated debug package is not
    # an installer artifact. Multiple main packages are an error, not a fallback.
    PACKAGE=''
    for CANDIDATE in ./*.pkg.tar.zst; do
        [ -f "$CANDIDATE" ] || continue
        PKGINFO=$(tar -xOf "$CANDIDATE" .PKGINFO)
        NAME=$(printf '%s\n' "$PKGINFO" | awk '$1 == "pkgname" && $2 == "=" {print $3}')
        [ "$NAME" = damage ] || continue
        [ -z "$PACKAGE" ] || { echo "Multiple damage packages found" >&2; exit 1; }
        ARCH=$(printf '%s\n' "$PKGINFO" | awk '$1 == "arch" && $2 == "=" {print $3}')
        [ "$ARCH" = x86_64 ] || { echo "Wrong package architecture" >&2; exit 1; }
        PACKAGE=$CANDIDATE
    done
    [ -n "$PACKAGE" ] || { echo "No damage package found" >&2; exit 1; }
    LISTING=$(tar -tf "$PACKAGE")
    printf '%s\n' "$LISTING" | awk '
        /(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {found=1}
        END {exit !found}
    ' || { echo "Production package does not contain bundled ERTS" >&2; exit 1; }

    # Keep the release NFT payload under the package output, matching the
    # canonical DEB/Mint release layout: _build/pkg/<format>/damage/nft/.
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
      "platform": "archlinux-x86_64",
      "package_format": "pkg.tar.zst",
      "architecture": "x86_64",
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
      "name": "DamageBDD Arch Linux Software Package",
      "description": "Production package with its Git SHA, package SHA-256 and installation path bound through the build release NFT metadata CID.",
      "project": "DamageBDD",
      "platform": "archlinux-x86_64",
      "package_path": "damage.pkg.tar.zst",
      "artifact_type": "arch_package",
      "package_format": "pkg.tar.zst",
      "build_system": "docker + rebar3 + makepkg",
      "build_profile": "prod",
      "ci_intent": "release",
      "network": "aeternity",
      "license": "Apache-2.0",
      "tags": [
        "damagebdd",
        "bdd",
        "ci",
        "supply-chain",
        "verifiable-artifacts"
      ]
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    When I prepare installation metadata in "meta" for platform "archlinux-x86_64" from IPFS asset hash in "asset_hash" with manifest path "installation.json"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"

    # Immutable release/platform identity: bump the packaged version for a new
    # build. Never use an asset/metadata CID as the installed release version.
    When I mint build release "{{build_release}}" for platform "archlinux-x86_64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    Then the latest installable build release must match the minted NFT
