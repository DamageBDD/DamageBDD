Feature: Build damagebdd package for Arch
  Scenario: Build package for Arch Linux
    When I build an image from Dockerfile at "QmatJahHtWEUKwwwak2wK2DTXuzQ6MGSi3MyDmTrUFR6KQ" as tag "damagebdd/arch-builder:latest" with params "--build-arg 'REPO_URL=https://github.com/DamageBDD/DamageBDD.git' --build-arg 'REPO_REF=develop'"
    Then I run docker image tagged "damagebdd/arch-builder:latest"
    """
    set -e

    cd /app

    git reset --hard
    git pull --ff-only --tags

    rm -f rebar.lock
    rm -rf _build

    DEBUG=1

    rebar3 as prod release

    export CUDA_LIB64=/opt/cuda/lib64/
    #DEBUG=1 rebar3 pkg gen -t arch
    rebar3 pkg gen -t arch

    cd _build/pkg/arch/damage/
    makepkg 

    # copy zst to host
    rm -f /out/*.zst
    cp -a *.zst /out/
    """
    Then I copy a file from the container to ipfs and store the hash in "asset_hash"
    When I add the path "docker/out/" to IPFS and store the hash in "asset_hash"

    When I set the JSON variable "meta" to:
    """
    {
        "name": "DamageBDD Arch Linux Software Package",
        "description": "This NFT represents a reproducible Arch Linux package build of DamageBDD. The artifact was built in a clean, deterministic environment using Arch packaging conventions, producing a verifiable binary anchored to IPFS. This token functions as an immutable supply-chain receipt, proving exactly what was built, how it was built, and enabling independent verification of the artifact.",
        "project": "DamageBDD",
        "artifact_type": "arch_package",
        "package_format": "pkg.tar.zst",
        "build_system": "docker + makepkg",
        "build_profile": "release",
        "ci_intent": "release",
        "distribution": "archlinux",
        "reproducible": true,
        "verifiable": true,
        "network": "aeternity",
        "license": "Apache-2.0",
        "tags": [
            "damagebdd",
            "bdd",
            "archlinux",
            "makepkg",
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
