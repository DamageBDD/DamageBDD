Feature: Test Webhooks API
  Scenario: Post feature data
    Given I am using server "https://staging.damagebdd.com"
    When I make a GET request to "/execute_feature/"
    Then the response status must be "200"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/webhooks/"
    """
    {
       "name": "TestHook{{timestamp}}",
       "url": "https://discord.com/api/webhooks/1236841971570577418/9fDR8KAJmaBwll283KFz1iyoYK18rHrUgTCyU2tIjqssrjgZNvzV1jeJgFRqk-bqSxEm"
    }
    """
    Then the response status must be "201"
    Then the json at path "$.status" must be "ok"
    When I make a GET request to "/webhooks/"
    Then the json at path "$[0].name" must be "TestHook{{timestamp}}"
