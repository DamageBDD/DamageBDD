@ecai @wikimedia @api @integration @ipfs @slow
Feature: Wikimedia index artifact is published to IPFS and becomes NFT-ready
  A completed fixture corpus with IPFS publication enabled must expose an
  immutable manifest CID and the metadata needed by the later minting step.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"

  Scenario: Publish the fixture index and retrieve its manifest by CID
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "fixture-ipfs-{{RunId}}"
    When I make a POST request to "/ecai/index-jobs"
    """
    {
      "schema": "ecai-index-job/v1",
      "kind": "wikimedia_visibility",
      "owner": "bdd-fixture-operator",
      "source": {
        "project": "enwiki",
        "pageview_project": "en.wikipedia",
        "content_release": "20260720",
        "pageview_months": [
          "2026-06"
        ],
        "catalog_path": "{{WIKIMEDIA_FIXTURE_CATALOG_PATH}}"
      },
      "target": {
        "index_id": "ecai-wikimedia-ipfs-{{RunId}}",
        "namespace": "org.damagebdd.bdd.wikimedia.ipfs",
        "base_dir": "/tmp/ecai-bdd-ipfs/{{RunId}}",
        "mode": "live_search",
        "previous_manifest_cid": null
      },
      "options": {
        "priority": 100,
        "max_retries": 1,
        "batch_size": 1,
        "limit": 3,
        "minimum_active_months": 1,
        "selection_shards": 8,
        "oversample_percent": 100,
        "partition_buffer_bytes": 4096,
        "abstract_max_bytes": 4096,
        "cirrus_max_line_bytes": 1048576,
        "index_chunk_lines": 100,
        "keep_downloads": false,
        "keep_intermediates": false,
        "publish_activity_ipfs": false,
        "publish_extracted_ipfs": false
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": true,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "202"
    And I store the JSON at path "$.job.id" in "IpfsJobId"

    And I wait "{{WIKIMEDIA_JOB_WAIT_SECONDS}}" seconds
    When I make a GET request to "/ecai/index-jobs/{{IpfsJobId}}"
    Then the response status must be "200"
    And the json at path "$.job.state" must be "ready_to_mint"

    When I make a GET request to "/ecai/index-jobs/{{IpfsJobId}}/artifact"
    Then the response status must be "200"
    And the json at path "$.artifact.ready_to_mint" must be "true"
    And the json at path "$.artifact.schema" must be "ecai-index-manifest/v2"
    And the json at path "$.nft_metadata.schema" must be "ecai-index-nft/v2"
    And I store the JSON at path "$.artifact.manifest_cid" in "ManifestCid"
    And the response must contain text "index_root"
    And the response must contain text "source_frontier_root"

    Given I am using server "{{IPFS_GATEWAY_URL}}"
    And I set "Accept" header to "application/octet-stream"
    When I make a GET request to "/ipfs/{{ManifestCid}}"
    Then the response status must be "200"
