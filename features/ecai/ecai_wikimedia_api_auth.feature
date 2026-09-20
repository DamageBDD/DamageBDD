@ecai @wikimedia @api @auth
Feature: Wikimedia API authorization
  Run this feature only on a node where protected ECAI routes require
  authorization.

  Scenario: A request without credentials is challenged
    Given I am using server "{{ecai_api_url}}"
    When I make a GET request to "/ecai/wikimedia/doctor"
    Then the response status must be one of "401,402"

  Scenario: An invalid bearer token is challenged
    Given I am using server "{{ecai_api_url}}"
    And I set "Authorization" header to "Bearer definitely-invalid"
    When I make a GET request to "/ecai/wikimedia/doctor"
    Then the response status must be one of "401,402"

  Scenario: The current authenticated session can authorize the configured ECAI origin
    Given I am using server "{{ecai_api_url}}"
    And I use the current ECAI authorization
    When I make a GET request to "/ecai/wikimedia/doctor"
    Then the response status must be "200"
