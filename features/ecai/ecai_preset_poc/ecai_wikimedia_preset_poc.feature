@ecai @wikimedia @preset @poc @integration
Feature: ECAI Wikimedia preset indexing proof of concept

  Scenario: Queue Simple English Wikipedia and observe the indexing worker
    Given I am using server "{{ecai_api_url}}"
    And I use the current ECAI authorization
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"

    When I make a GET request to "/ecai/index-jobs/status"
    Then the response status must be "200"
    Then the JSON at path "$.status.max_concurrency" should be "1"

    When I make a GET request to "/ecai/index-jobs/presets"
    Then the response status must be "200"
    Then the response must contain text "simplewiki"

    Given I store an uuid in "RequestId"
    And I set "Idempotency-Key" header to "ecai-poc-simplewiki-{{RequestId}}"

    When I make a POST request to "/ecai/index-jobs/presets/simplewiki"
    """
    {}
    """
    Then the response status must be "202"
    Then the response must contain text "wikimedia_visibility"
    Then I store the JSON at path "$.job.id" in "IndexJobId"
    Then I print the response

    And I wait "20" seconds
    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}"
    Then the response status must be "200"
    Then the JSON at path "$.job.state" should be "running"
    Then the response must contain text "progress"
    Then I print the response

    When I make a POST request to "/ecai/index-jobs/{{IndexJobId}}/cancel"
    """
    {}
    """
    Then the response status must be "202"
    Then the response must contain text "cancel"

    And I wait "5" seconds
    When I make a GET request to "/ecai/index-jobs/{{IndexJobId}}"
    Then the response status must be "200"
    Then the response must contain text "cancel"
    Then I print the response
