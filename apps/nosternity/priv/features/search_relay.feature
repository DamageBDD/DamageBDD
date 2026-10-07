Feature: Nosternity search relay API
  The local Nosternity listener exposes relay metadata and bounded ECAI search.
  These steps use the existing DamageBDD steps_http module.

  Scenario: Discover supported relay NIPs
    Given I am using server "http://127.0.0.1:9001"
    And I set "Accept" header to "application/nostr+json"
    When I make a GET request to "/nostr"
    Then the response status must be "200"
    And the response must contain text "supported_nips"
    And the response must contain text "Nosternity Search"

  Scenario: Query indexed data using NIP-50 filters
    Given I am using server "http://127.0.0.1:9001"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/api/nostr/search"
      """
      {"filters":[{"search":"DamageBDD","kinds":[1,30023],"limit":10}]}
      """
    Then the response status must be "200"
    And the response must contain text "results"

  Scenario: Reject malformed filters
    Given I am using server "http://127.0.0.1:9001"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/api/nostr/search"
      """
      {"filters":[{"limit":-1}]}
      """
    Then the response status must be "400"
    And the response must contain text "invalid_filters"

  Scenario: Build grounded context without invoking a model
    Given I am using server "http://127.0.0.1:9001"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/api/nostr/context"
      """
      {"query":"DamageBDD","question":"Summarize the indexed notes","limit":4}
      """
    Then the response status must be "200"
    And the response must contain text "sources"
