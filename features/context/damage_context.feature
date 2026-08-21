@api @context
Feature: Context API
  The context API stores versioned account values off-chain, redacts sensitive
  values from responses, supports atomic updates, and rejects stale writes.

  Background:
    Given I am using server "{{{api_url}}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{access_token}}}"

  Scenario: Challenge an invalid public access token with L402
    And I set "Authorization" header to "Bearer invalid-context-token"
    When I make a GET request to "/context"
    Then the response status must be "402"

  Scenario: Store and read a public context value
    Given I store an uuid in "public_context_key"
    When I make a POST request to "/context"
    """
    {
      "key": "{{public_context_key}}",
      "value": "plain-context-value",
      "sensitive": false
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

    When I make a GET request to "/context"
    Then the response status must be "200"
    Then the response must contain text "{{public_context_key}}"
    Then the response must contain text "plain-context-value"

    When I make a DELETE request to "/context?key={{public_context_key}}"
    Then the response status must be "200"

  Scenario: Store and redact a sensitive context value
    Given I store an uuid in "sensitive_context_key"
    When I make a POST request to "/context"
    """
    {
      "key": "{{sensitive_context_key}}",
      "value": "bdd-context-secret-value",
      "sensitive": true
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

    When I make a GET request to "/context"
    Then the response status must be "200"
    Then the response must contain text "{{sensitive_context_key}}"
    Then the response must contain text "XX-REDACTED-XX"

    When I make a DELETE request to "/context?key={{sensitive_context_key}}"
    Then the response status must be "200"

  Scenario: Apply an atomic context change set
    Given I store an uuid in "context_delete_key"
    And I store an uuid in "context_batch_key"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_delete_key}}",
      "value": "delete-me"
    }
    """
    Then the response status must be "200"

    When I make a PATCH request to "/context"
    """
    {
      "set": {
        "{{context_batch_key}}": {
          "value": "batch-public-value",
          "sensitive": false
        }
      },
      "delete": [
        "{{context_delete_key}}"
      ]
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

    When I make a GET request to "/context"
    Then the response status must be "200"
    Then the response must contain text "{{context_batch_key}}"
    Then the response must contain text "batch-public-value"

    When I make a DELETE request to "/context?key={{context_batch_key}}"
    Then the response status must be "200"

  Scenario: Reject a stale context version
    Given I store an uuid in "stale_context_key"
    When I make a PATCH request to "/context"
    """
    {
      "expected_version": 2147483647,
      "set": {
        "{{stale_context_key}}": "must-not-be-written"
      },
      "delete": []
    }
    """
    Then the response status must be "409"
    Then the json at path "$.error" must be "VERSION_CONFLICT"

  Scenario: Reject a non-object JSON request
    When I make a POST request to "/context"
    """
    []
    """
    Then the response status must be "400"
    Then the json at path "$.error" must be "JSON_OBJECT_REQUIRED"

  Scenario: Reject an empty context key
    When I make a POST request to "/context"
    """
    {
      "key": "",
      "value": "invalid"
    }
    """
    Then the response status must be "422"
