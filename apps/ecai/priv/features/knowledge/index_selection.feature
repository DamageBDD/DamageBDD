@knowledge @index_selection
Feature: Search only explicitly selected knowledge indexes
  A caller can choose logical indexes without choosing filesystem paths or owners.
  An empty selection must never be interpreted as all indexes.

  Background:
    Given I am using server "{{ecai_api}}"
    Given I set "Content-Type" header to "application/json"

  Scenario: An empty selection performs no backend searches
    When I make a POST request to "/ecai/knowledge/search"
      """
      {"q":"redire","indexes":[]}
      """
    Then the response status must be "200"
    Then the JSON at path "$.selection" should be
      """
      {"mode":"selected","indexes":[]}
      """
    Then the JSON at path "$.backends" should be
      """
      []
      """
    Then the JSON at path "$.results" should be
      """
      []
      """

  Scenario: A shared-only search retains its selection even if the index is unavailable
    When I make a POST request to "/ecai/knowledge/search"
      """
      {"q":"redire","indexes":["shared"]}
      """
    Then the response status must be "200"
    Then the JSON at path "$.selection" should be
      """
      {"mode":"selected","indexes":["shared"]}
      """

  Scenario: A filesystem path cannot select a search backend
    When I make a POST request to "/ecai/knowledge/search"
      """
      {"q":"redire","indexes":["/tmp/not-a-logical-index"]}
      """
    Then the response status must be "400"
    Then the response must contain text "invalid_index_selection"

  Scenario: Null is not an empty list or the all-indexes default
    When I make a POST request to "/ecai/knowledge/search"
      """
      {"q":"redire","indexes":null}
      """
    Then the response status must be "400"
    Then the response must contain text "invalid_index_selection"
