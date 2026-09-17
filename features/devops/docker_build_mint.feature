# Example based on the supplied build feature. Configure the shared NFT/index
# before running, and serialize mint/oracle/publication for this NFT contract.
Feature: Publish an installable Mint 22 / Ubuntu Noble amd64 release
  Scenario: Build package for mint
    When I build an image from Dockerfile at "Qmae3bWqpfZ7ShivY3AChBrhobb6mwGmpNhQSRhkqVYXA7" as tag "damagebdd/mint22-builder:latest"
    Then I run docker image tagged "damagebdd/mint22-builder:latest"
    """
    set -eu
    cd /opt/workspace

    # Hold one lock across validation, clean, release, package and staging.
    # The lock must be outside _build and must never be unlinked by cleanup.
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
    git describe --tags --always --dirty

    sh bin/check-beam-sources.sh

    # Preserve the dependency set committed with this checkout.
    test -f rebar.lock
    git diff --exit-code HEAD -- rebar.lock
    GIT_SHA=$(git rev-parse HEAD)
    rm -rf _build
    export DEBUG=1

    rebar3 as prod release
    git diff --exit-code HEAD -- rebar.lock
    rebar3 as prod pkg gen -t deb

    # Match the working Arch build: stage in the container-owned workspace.
    # Do not write to the runner's /out bind mount.
    NFT_DIR="$PWD/_build/pkg/deb/damage/nft"
    mkdir -p "$NFT_DIR"
    set -- _build/pkg/deb/*.deb
    [ "$#" -eq 1 ] && [ -f "$1" ] || {
        echo "Expected exactly one production DEB" >&2
        exit 1
    }
    test "$(dpkg-deb -f "$1" Package)" = damage
    test "$(dpkg-deb -f "$1" Architecture)" = amd64

    # List/check the archive before publishing; never extract or execute it here.
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
    git describe --tags --always --dirty > "$NFT_DIR/GIT_DESCRIBE"
    (
        cd "$NFT_DIR"
        sha256sum damage.deb > SHA256SUMS
        DIGEST=$(awk '{print $1}' SHA256SUMS)
        cat > installation.json <<JSON
    {
      "schema_version": 1,
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
        "name": "DamageBDD Mint 22 Software Package",
        "description": "DamageBDD production package built by the configured Mint 22 pipeline. The NFT records the output and metadata CIDs. The publication index separately records the package path and SHA-256.",
        "project": "DamageBDD",
        "platform": "ubuntu-noble-amd64",
        "package_path": "damage.deb",
        "artifact_type": "debian_package",
        "build_system": "docker + rebar3",
        "build_profile": "prod",
        "ci_intent": "release",
        "network": "aeternity",
        "license": "Apache-2.0",
        "tags": [
            "damagebdd",
            "bdd",
            "ci",
            "reproducible-builds",
            "supply-chain",
            "verifiable-artifacts",
            "infrastructure-nft"
        ]
    }

    """

    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    When I prepare installation metadata in "meta" for platform "ubuntu-noble-amd64" from IPFS asset hash in "asset_hash" with manifest path "installation.json"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    # Use a NEW deterministic release key for the corrected metadata.
    # The previous successful mint may already own the asset-CID default key.
    When I mint build release "install-{{meta_hash}}" for platform "ubuntu-noble-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    And I post the minted build release NFT to nostr
