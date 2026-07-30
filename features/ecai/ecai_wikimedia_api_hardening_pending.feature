@ecai @wikimedia @api @security @pending
Feature: Pending Wikimedia API hardening contracts
  These scenarios document merge-gate behaviour identified during review.
  They are intentionally tagged pending until the corresponding validation
  and path policy is implemented.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"

  Scenario: Duplicate pageview months are rejected instead of double-counted
    Given I store an uuid in "RunId"
    When I make a POST request to "/ecai/index-jobs"
    """
    {
      "schema": "ecai-index-job/v1",
      "kind": "wikimedia_visibility",
      "source": {
        "project": "enwiki",
        "pageview_project": "en.wikipedia",
        "content_release": "20260720",
        "pageview_months": [
          "2026-06",
          "2026-06"
        ]
      },
      "target": {
        "index_id": "duplicate-months-{{RunId}}",
        "namespace": "org.damagebdd.pending",
        "base_dir": "/tmp/ecai-bdd-pending/{{RunId}}",
        "mode": "live_search"
      },
      "options": {
        "limit": 10,
        "minimum_active_months": 1,
        "selection_shards": 8
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": false,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "422"
    And the response must contain text "duplicate_pageview_month"

  Scenario: Catalog paths outside the configured operator root are rejected
    Given I store an uuid in "RunId"
    When I make a POST request to "/ecai/index-jobs"
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
        ],
        "catalog_path": "/etc/shadow"
      },
      "target": {
        "index_id": "unsafe-catalog-{{RunId}}",
        "namespace": "org.damagebdd.pending",
        "base_dir": "/tmp/ecai-bdd-pending/{{RunId}}",
        "mode": "live_search"
      },
      "options": {
        "limit": 10,
        "minimum_active_months": 1,
        "selection_shards": 8
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": false,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "422"
    And the response must contain text "catalog_path_outside_allowed_root"

  Scenario: Target directories outside the configured index root are rejected
    Given I store an uuid in "RunId"
    When I make a POST request to "/ecai/index-jobs"
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
        "index_id": "unsafe-target-{{RunId}}",
        "namespace": "org.damagebdd.pending",
        "base_dir": "/etc/ecai-index",
        "mode": "live_search"
      },
      "options": {
        "limit": 10,
        "minimum_active_months": 1,
        "selection_shards": 8
      },
      "finalize": {
        "build_nft_manifest": true,
        "publish_ipfs": false,
        "auto_mint": false
      }
    }
    """
    Then the response status must be "422"
    And the response must contain text "base_dir_outside_allowed_root"
