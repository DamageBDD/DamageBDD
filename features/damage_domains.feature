Feature: Test DamageBDD Domains API

  Background:
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{damagebdd_access_token}}}"

  Scenario: Post feature data
    When I make a POST request to "/domains/"
    """
    {
       "domain": "staging.damagebdd.com"
    }
    """
    Then the response status must be "201"
    Then the length of json at path "$.token" must be greater than "0"
    When I make a GET request to "/domains/"
    Then the json at path "$[0].domain" must be "staging.damagebdd.com"
