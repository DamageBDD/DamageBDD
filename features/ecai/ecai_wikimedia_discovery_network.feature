@ecai @wikimedia @api @network
Feature: Wikimedia source discovery API
  These scenarios contact the official Wikimedia dump endpoints. Run them
  separately from the deterministic contract suite.

  Background:
    Given I am using server "{{ECAI_BASE_URL}}"
    And I set "Authorization" header to "Bearer {{ECAI_ACCESS_TOKEN}}"
    And I set "Accept" header to "application/json"

  Scenario: List available Wikimedia source releases
    When I make a GET request to "/ecai/wikimedia/sources?project=enwiki&pageview_project=en.wikipedia&months={{WIKIMEDIA_MONTH}}"
    Then the response status must be "200"
    And the json at path "$.sources.schema" must be "ecai-wikimedia-catalog/v1"
    And the json at path "$.sources.project" must be "enwiki"
    And the json at path "$.sources.pageview_project" must be "en.wikipedia"
    And the response must contain text "{{WIKIMEDIA_MONTH}}"
    And the response must contain text "available_cirrus_releases"

  Scenario: Plan a small pinned Wikimedia corpus
    When I make a GET request to "/ecai/wikimedia/plan?project=enwiki&pageview_project=en.wikipedia&content_release={{WIKIMEDIA_RELEASE}}&months={{WIKIMEDIA_MONTH}}&limit=10&minimum_active_months=1&selection_shards=8&publish_ipfs=false&publish_activity_ipfs=false"
    Then the response status must be "200"
    And the json at path "$.plan.spec.kind" must be "wikimedia_visibility"
    And the json at path "$.plan.catalog.project" must be "enwiki"
    And the json at path "$.plan.estimated_work_units.target_records" must be "10"
    And the response must contain text "{{WIKIMEDIA_RELEASE}}"

  Scenario: The operator doctor reports all dependency domains
    When I make a GET request to "/ecai/wikimedia/doctor"
    Then the response status must be "200"
    And the response must contain text "bzip2"
    And the response must contain text "index_jobs"
    And the response must contain text "search"
    And the response must contain text "source_catalog"
