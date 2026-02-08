Feature: Build damagebdd package for mint
  Scenario: Build package for mint
    When I build an image from Dockerfile at "QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS" as tag "damagebdd/mint22-builder:latest"
    Then I run docker image tagged "damagebdd/mint22-builder:latest"
    """
    set -e

    git reset --hard

    rm -f rebar.lock
    rm -rf _build

    DEBUG=1

    rebar3 as prod release
    rebar3 pkg gen -t deb

    # copy debs to host
    rm -f /out/*.deb
    cp -a _build/pkg/deb/*.deb /out/
    """
    When I add the path "docker/out/" to IPFS and store the hash in "asset_hash"

    When I set the JSON variable "meta" to:
    """
    {
        "name": "DamageBDD Mint 22 Software Package",
        "description": "This NFT represents a reproducible, CI-built DamageBDD package (Mint 22). The artifact was built from a clean Docker environment, packaged via rebar3, and cryptographically anchored to IPFS. This token serves as a verifiable supply-chain receipt proving exactly what was built, how it was built, and when it was minted.",
        "project": "DamageBDD",
        "artifact_type": "debian_package",
        "build_system": "docker + rebar3",
        "build_profile": "prod",
        "ci_intent": "release",
        "reproducible": true,
        "verifiable": true,
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
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"

    When I mint an NFT with metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
