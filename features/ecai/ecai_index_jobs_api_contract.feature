@ecai @index-jobs @api @contract
Feature: Durable index-job API contract
  Operators must be able to enqueue, inspect, pause, resume, cancel and observe
  indexing jobs through a deterministic API. The contract profile sets
  index_jobs_max_concurrency to zero so no job leaves the queue unexpectedly.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"

  Scenario: A queued job can be inspected, paused, resumed and canceled
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "index-lifecycle-{{RunId}}"
    When I make a POST request to "/ecai/index-jobs"
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
    And the response must contain text "queue_position"
    And I store the JSON at path "$.job.id" in "IndexJobId"

    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}"
    Then the response status must be "200"
    And the json at path "$.job.id" must be "{{IndexJobId}}"
    And the json at path "$.job.state" must be "queued"

    When I make a GET request to "/ecai/index-jobs?state=queued&kind=wikimedia_visibility&limit=100"
    Then the response status must be "200"
    And the response must contain text "{{IndexJobId}}"

    When I make a GET request to "/ecai/index-jobs/status"
    Then the response status must be "200"
    And the json at path "$.status.max_concurrency" must be "0"
    And the response must contain text "queued_jobs"

    When I make a POST request to "/ecai/index-jobs/{{IndexJobId}}/pause"
    """
    {}
    """
    Then the response status must be "202"
    And the json at path "$.job.state" must be "paused"

    Given I set "Accept" header to "text/event-stream"
    And I set "Last-Event-ID" header to "1"
    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}/events"
    Then the response status must be "200"
    And the "Content-Type" header should be "text/event-stream"
    And the response must contain text "event: state"
    And the response must contain text "paused"

    Given I set "Accept" header to "application/json"
    And I set "Last-Event-ID" header to "0"
    When I make a POST request to "/ecai/index-jobs/{{IndexJobId}}/resume"
    """
    {}
    """
    Then the response status must be "202"
    And the json at path "$.job.state" must be "queued"

    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}/artifact"
    Then the response status must be "409"
    And the json at path "$.error" must be "artifact_not_ready"

    When I make a POST request to "/ecai/index-jobs/{{IndexJobId}}/cancel"
    """
    {}
    """
    Then the response status must be "202"
    And the json at path "$.job.state" must be "canceled"

    When I make a POST request to "/ecai/index-jobs/{{IndexJobId}}/retry"
    """
    {}
    """
    Then the response status must be "409"
    And the response must contain text "invalid_state"
    And the response must contain text "canceled"

    Given I set "Accept" header to "text/event-stream"
    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}/events"
    Then the response status must be "200"
    And the response must contain text "canceled"

  Scenario: Reusing an idempotency key with the same specification returns the same job
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "same-spec-{{RunId}}"
    When I make a POST request to "/ecai/index-jobs"
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
    And I store the JSON at path "$.job.id" in "FirstJobId"

    When I make a POST request to "/ecai/index-jobs"
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
    And the json at path "$.job.id" must be "{{FirstJobId}}"

    When I make a POST request to "/ecai/index-jobs/{{FirstJobId}}/cancel"
    """
    {}
    """
    Then the response status must be "202"

  Scenario: Reusing an idempotency key with a different specification is a conflict
    Given I store an uuid in "RunId"
    And I set "Idempotency-Key" header to "conflict-{{RunId}}"
    When I make a POST request to "/ecai/index-jobs"
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
    And I store the JSON at path "$.job.id" in "ConflictingJobId"

    When I make a POST request to "/ecai/index-jobs"
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
        "index_id": "ecai-bdd-conflict-{{RunId}}",
        "namespace": "org.damagebdd.bdd.wikimedia",
        "base_dir": "/tmp/ecai-bdd/{{RunId}}-conflict",
        "mode": "live_search"
      },
      "options": {
        "limit": 11,
        "minimum_active_months": 1,
        "selection_shards": 8,
        "publish_activity_ipfs": false
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": false,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "409"
    And the response must contain text "idempotency_conflict"

    When I make a POST request to "/ecai/index-jobs/{{ConflictingJobId}}/cancel"
    """
    {}
    """
    Then the response status must be "202"

  Scenario: Unknown jobs return not found
    When I make a GET request to "/ecai/index-jobs/ijob-does-not-exist"
    Then the response status must be "404"
    And the json at path "$.error" must be "not_found"

    When I make a GET request to "/ecai/index-jobs/ijob-does-not-exist/events"
    Then the response status must be "404"
    And the json at path "$.error" must be "not_found"
