Feature: Build damagebdd package for mint
  Scenario: Build package for mint
    When I build an image from Dockerfile at "QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS" as tag "damagebdd/mint22-builder:latest"
    Then I run docker image tagged "damagebdd/mint22-builder:latest"
    """
    set -e
    git reset --hard
    # optional, only if this is actually a git clone:
    if [ -d .git ]; then git pull --ff-only --tags || true; fi

    rm -f rebar.lock
    rm -rf _build

    DEBUG=1
    rebar3 as prod release

    # package with your plugin
    rebar3 pkg gen -t deb

    # copy debs to host
    rm -f /out/*.deb
    cp -a _build/pkg/deb/*.deb /out/
    """
    When I add the path "deb/" to IPFS and store the hash in "asset_hash"

    When I set the JSON variable "meta" to:
    """
      {"name":"My Artifact","description":"from CI"}
    """

    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    When I add the path "meta.json" to IPFS and store the hash in "meta_hash"

    When I mint an NFT with metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
