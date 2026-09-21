# Installation builds and the serving API must share ae_network_id and
# build_release_nft_contract. See docs/release-discovery.md.
# Mint 22 intentionally publishes the same Noble/amd64 target as Ubuntu.
# Use one canonical publisher per release/platform pair; do not overwrite it.
Feature: Publish an installable Mint 22 / Ubuntu Noble release
  Scenario: Build and verify the ubuntu-noble-amd64 installation release
    Given the build release discovery is configured
    When I build an image from Dockerfile at "Qmae3bWqpfZ7ShivY3AChBrhobb6mwGmpNhQSRhkqVYXA7" as tag "damagebdd/mint22-builder:latest"
    Then I run docker image tagged "damagebdd/mint22-builder:latest"
    """
    set -eu
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

    . /etc/os-release
    [ "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" = noble ] || {
        echo "This artifact must be built on an Ubuntu Noble base" >&2
        exit 1
    }
    [ "$(dpkg --print-architecture)" = amd64 ] || {
        echo "This feature publishes only ubuntu-noble-amd64" >&2
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

    rebar3 as prod pkg gen -t deb
    git diff --exit-code HEAD -- rebar.lock

    # Export only the package, its manifest and provenance, not the whole build.
    NFT_DIR="$PWD/_build/pkg/deb/damage/nft"
    mkdir -p "$NFT_DIR"
    set -- _build/pkg/deb/*.deb
    [ "$#" -eq 1 ] && [ -f "$1" ] || {
        echo "Expected exactly one production DEB" >&2
        exit 1
    }
    test "$(dpkg-deb -f "$1" Package)" = damage
    test "$(dpkg-deb -f "$1" Architecture)" = amd64

    # Inspect, but never execute/extract, package content during publication.
    LISTING=$(dpkg-deb --contents "$1")
    printf '%s\n' "$LISTING" | awk '
        $NF ~ /(^|\/)erts-[^/]+\/bin\/beam\.smp$/ {found=1}
        END {exit !found}
    ' || {
        echo "Production DEB does not contain bundled ERTS" >&2
        exit 1
    }
    install -m 0644 "$1" "$NFT_DIR/damage.deb"

    printf '%s\n' "$GIT_SHA" > "$NFT_DIR/GIT_COMMIT"
    printf '%s\n' "$RELEASE_VSN" > "$NFT_DIR/RELEASE_VERSION"
    git -C /opt/workspace describe --tags --always --dirty > "$NFT_DIR/GIT_DESCRIBE"
    (
        cd "$NFT_DIR"
        sha256sum damage.deb > SHA256SUMS
        DIGEST=$(awk '{print $1}' SHA256SUMS)
        cat > installation.json <<JSON
    {
      "schema_version": 1,
      "release": "$RELEASE_VSN",
      "platform": "ubuntu-noble-amd64",
      "package_format": "deb",
      "architecture": "amd64",
      "asset_path": "damage.deb",
      "sha256": "$DIGEST",
      "git_sha": "$GIT_SHA"
    }
    JSON
    )
    find "$NFT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
    """
    Then I copy file "/opt/workspace/_build/pkg/deb/damage/nft/" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "DamageBDD Mint 22 / Ubuntu Noble Software Package",
      "description": "Production package with its Git SHA, package SHA-256 and installation path bound through the build release NFT metadata CID.",
      "project": "DamageBDD",
      "platform": "ubuntu-noble-amd64",
      "package_path": "damage.deb",
      "artifact_type": "debian_package",
      "package_format": "deb",
      "build_system": "docker + rebar3",
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
    When I prepare installation metadata in "meta" for platform "ubuntu-noble-amd64" from IPFS asset hash in "asset_hash" with manifest path "installation.json"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"

    # Immutable release/platform identity: bump the packaged version for a new
    # build. Never use an asset/metadata CID as the installed release version.
    When I mint build release "{{build_release}}" for platform "ubuntu-noble-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    Then the latest installable build release must match the minted NFT
    And I post the minted build release NFT to nostr
