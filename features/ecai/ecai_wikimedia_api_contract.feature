@ecai @wikimedia @api @contract
Feature: Wikimedia visibility API contract
  The Wikimedia operator API must reject malformed input, expose stable
  validation errors, and enqueue deterministic index jobs without doing
  network or indexing work in the contract-test profile.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"

  Scenario: Search rejects a missing query
    When I make a GET request to "/ecai/wikimedia/search"
    Then the response status must be "400"
    And the json at path "$.error" must be "missing_query"

  Scenario: Search rejects an invalid numeric filter
    When I make a GET request to "/ecai/wikimedia/search?q=ecai&limit=not-a-number"
    Then the response status must be "400"
    And the response must contain text "invalid_parameter"
    And the response must contain text "limit"

  Scenario: Search accepts a well-formed query when the search context is ready
    When I make a GET request to "/ecai/wikimedia/search?q=ecai&limit=5&dedupe_entities=true"
    Then the response status must be "200"
    And the json at path "$.search.query" must be "ecai"
    And the response must contain text "matched_documents"
    And the response must contain text "matched_entities"

  Scenario: Index creation rejects malformed JSON
    When I make a POST request to "/ecai/wikimedia/index"
    """
    {"kind":
    """
    Then the response status must be "400"
    And the response must contain text "invalid_json"

  Scenario: Index creation requires a JSON object
    When I make a POST request to "/ecai/wikimedia/index"
    """
    []
    """
    Then the response status must be "400"
    And the json at path "$.error" must be "json_object_required"

  Scenario: Automatic minting remains disabled until Step 4B
    Given I store an uuid in "RunId"
    When I make a POST request to "/ecai/wikimedia/index"
    """
    {
      "schema": "ecai-index-job/v1",
      "kind": "wikimedia_visibility",
      "source": {
        "project": "enwiki",
        "pageview_project": "en.wikipedia",
        "content_release": "20260720",
        "pageview_months": [
          "2026-06"
        ]
      },
      "target": {
        "index_id": "ecai-auto-mint-{{RunId}}",
        "namespace": "org.damagebdd.bdd.wikimedia",
        "base_dir": "/tmp/ecai-bdd/{{RunId}}",
        "mode": "live_search"
      },
      "options": {
        "limit": 10,
        "minimum_active_months": 1,
        "selection_shards": 8,
        "publish_activity_ipfs": false
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": false,
        "auto_mint": true
      }
    }
    """
    Then the response status must be "422"
    And the response must contain text "step4b_required"

  Scenario: The Wikimedia convenience endpoint returns job and control links
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "wikimedia-contract-{{RunId}}"
    When I make a POST request to "/ecai/wikimedia/index"
    """
    {
      "schema": "ecai-index-job/v1",
      "kind": "wikimedia_visibility",
      "owner": "bdd-operator",
      "source": {
        "project": "enwiki",
        "pageview_project": "en.wikipedia",
        "content_release": "20260720",
        "pageview_months": [
          "2026-06"
        ]
      },
      "target": {
        "index_id": "ecai-bdd-{{RunId}}",
        "namespace": "org.damagebdd.bdd.wikimedia",
        "base_dir": "/tmp/ecai-bdd/{{RunId}}",
        "mode": "live_search",
        "previous_manifest_cid": null
      },
      "options": {
        "priority": 100,
        "max_retries": 1,
        "batch_size": 1,
        "limit": 10,
        "minimum_active_months": 1,
        "selection_shards": 8,
        "oversample_percent": 100,
        "partition_buffer_bytes": 4096,
        "abstract_max_bytes": 1024,
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
    And the json at path "$.job.state" must be "queued"
    And the json at path "$.job.spec.kind" must be "wikimedia_visibility"
    And I store the JSON at path "$.job.id" in "WikimediaJobId"
    And the json at path "$.events" must be "/ecai/index-jobs/{{WikimediaJobId}}/events"
    And the json at path "$.controls.pause" must be "/ecai/index-jobs/{{WikimediaJobId}}/pause"
    And the json at path "$.controls.resume" must be "/ecai/index-jobs/{{WikimediaJobId}}/resume"
    And the json at path "$.controls.cancel" must be "/ecai/index-jobs/{{WikimediaJobId}}/cancel"
    When I make a POST request to "/ecai/index-jobs/{{WikimediaJobId}}/cancel"
    """
    {}
    """
    Then the response status must be "202"
    And the json at path "$.job.state" must be "canceled"
