Feature: Build package into an nft
  Scenario: Build package nft

    When I set the JSON variable "meta"
    """
    {
        "name": "DamageBDD Ubuntu 24.04 LTS Software Package",
        "description": "This NFT represents a reproducible, CI-built DamageBDD package (Ubuntu 24). The artifact was built from a clean Docker environment, packaged via rebar3, and cryptographically anchored to IPFS. This token serves as a verifiable supply-chain receipt proving exactly what was built, how it was built, and when it was minted.",
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

    When I set JSON key "file_ipfs" to "QmSHehPvNQvnHZQsqTZfiQ1hwFHZPAhA57F1ujWo79PHFB" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    And I print "{{meta_hash}}"

    When I mint an NFT with metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    And I print "{{mint}}"
