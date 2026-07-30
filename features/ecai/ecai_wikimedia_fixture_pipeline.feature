@ecai @wikimedia @api @integration @slow
Feature: Wikimedia fixture corpus end-to-end API
  A tiny local pageview and Cirrus corpus must travel through source pinning,
  selection, indexing, artifact finalization and entity-deduplicated search.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"

  Scenario: Build and search a deterministic local Wikimedia corpus
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "fixture-pipeline-{{RunId}}"
    When I make a POST request to "/ecai/wikimedia/index"
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
        "index_id": "ecai-wikimedia-fixture-{{RunId}}",
        "namespace": "org.damagebdd.bdd.wikimedia.fixture",
        "base_dir": "/tmp/ecai-bdd-integration/{{RunId}}",
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
        "publish_ipfs": false,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "202"
    And I store the JSON at path "$.job.id" in "FixtureJobId"

    And I wait "{{WIKIMEDIA_JOB_WAIT_SECONDS}}" seconds
    When I make a GET request to "/ecai/index-jobs/{{FixtureJobId}}"
    Then the response status must be "200"
    And the json at path "$.job.state" must be "{{WIKIMEDIA_EXPECTED_TERMINAL_STATE}}"
    And the json at path "$.job.result.kind" must be "wikimedia_visibility"
    And the json at path "$.job.result.records_indexed" must be "3"

    When I make a GET request to "/ecai/index-jobs/{{FixtureJobId}}/artifact"
    Then the response status must be "200"
    And the json at path "$.artifact.schema" must be "ecai-index-manifest/v1"
    And the response must contain text "index_root"
    And the response must contain text "source_frontier_root"

    When I make a GET request to "/ecai/wikimedia/search?q=quantum&limit=10&has_wikidata=true&dedupe_entities=true"
    Then the response status must be "200"
    And the json at path "$.search.matched_documents" must be "2"
    And the json at path "$.search.matched_entities" must be "1"
    And the json at path "$.search.count" must be "1"
    And the response must contain text "Q944"
    And the response must contain text "Quantum mechanics"

    When I make a GET request to "/ecai/wikimedia/search?q=quantum&limit=10&has_wikidata=true&dedupe_entities=false"
    Then the response status must be "200"
    And the json at path "$.search.matched_documents" must be "2"
    And the json at path "$.search.matched_entities" must be "1"
    And the json at path "$.search.count" must be "2"
