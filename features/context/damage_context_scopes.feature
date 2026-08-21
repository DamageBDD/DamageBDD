@api @context
Feature: Scoped context API
  Account and node contexts are isolated, versioned, and stored off-chain.
  Sensitive values are redacted, mutations are atomic, and frozen context
  proofs are published to IPFS as part of each execution report.

  Background:
    Given I am using server "{{{api_url}}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{access_token}}}"

  Scenario: Store and read isolated account context
    Given I store an uuid in "context_case_id"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-public",
      "value": "https://account.example.test",
      "sensitive": false
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-secret",
      "value": "account-secret-value",
      "sensitive": true
    }
    """
    Then the response status must be "200"

    When I make a GET request to "/context"
    Then the response status must be "200"
    Then the json at path "$.scope.kind" must be "account"
    Then the response must contain text "{{context_case_id}}-public"
    Then the response must contain text "https://account.example.test"
    Then the response must contain text "{{context_case_id}}-secret"
    Then the response must contain text "XX-REDACTED-XX"

    When I make a DELETE request to "/context?key={{context_case_id}}-public"
    Then the response status must be "200"

    When I make a DELETE request to "/context?key={{context_case_id}}-secret"
    Then the response status must be "200"

  Scenario: Apply an atomic account change set
    Given I store an uuid in "context_case_id"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-delete",
      "value": "delete-me"
    }
    """
    Then the response status must be "200"

    When I make a PATCH request to "/context"
    """
    {
      "set": {
        "{{context_case_id}}-batch": {
          "value": "batch-value",
          "sensitive": false
        }
      },
      "delete": [
        "{{context_case_id}}-delete"
      ]
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

    When I make a GET request to "/context"
    Then the response status must be "200"
    Then the response must contain text "{{context_case_id}}-batch"
    Then the response must contain text "batch-value"

    When I make a DELETE request to "/context?key={{context_case_id}}-batch"
    Then the response status must be "200"

  Scenario: Reject a stale account context version
    Given I store an uuid in "stale_account_key"
    When I make a PATCH request to "/context"
    """
    {
      "expected_version": 2147483647,
      "set": {
        "{{stale_account_key}}": "must-not-be-written"
      },
      "delete": []
    }
    """
    Then the response status must be "409"
    Then the json at path "$.error" must be "VERSION_CONFLICT"

  Scenario: Reject a protected runtime key
    When I make a POST request to "/context"
    """
    {
      "key": "public_key",
      "value": "ak_not_the_authenticated_account"
    }
    """
    Then the response status must be "422"


  # Authenticated non-admin authorization is covered separately by
  # damage_context_node_authz.feature, which runs under a non-admin principal.
  @node-admin
  Scenario: Merge node defaults, account overrides, and locked node values
    Given I store an uuid in "context_case_id"
    When I make a POST request to "/node/context"
    """
    {
      "key": "{{context_case_id}}-shared",
      "value": "node-default",
      "inheritance": "default",
      "exposure": "template"
    }
    """
    Then the response status must be "200"

    When I make a POST request to "/node/context"
    """
    {
      "key": "{{context_case_id}}-locked",
      "value": "node-locked",
      "inheritance": "locked",
      "exposure": "template"
    }
    """
    Then the response status must be "200"

    When I make a POST request to "/node/context"
    """
    {
      "key": "{{context_case_id}}-node-secret",
      "value": "node-private-value",
      "sensitive": true,
      "inheritance": "default",
      "exposure": "template"
    }
    """
    Then the response status must be "200"

    When I make a GET request to "/node/context"
    Then the response status must be "200"
    Then the json at path "$.scope.kind" must be "node"
    Then the response must contain text "{{context_case_id}}-node-secret"
    Then the response must contain text "XX-REDACTED-XX"
    Then the response must contain text "step_only"


    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-shared",
      "value": "account-override"
    }
    """
    Then the response status must be "200"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-locked",
      "value": "account-cannot-override"
    }
    """
    Then the response status must be "200"

    When I make a GET request to "/context/effective"
    Then the response status must be "200"
    Then the response must contain text "account-override"
    Then the response must contain text "node-locked"

    When I make a DELETE request to "/context?key={{context_case_id}}-shared"
    Then the response status must be "200"

    When I make a DELETE request to "/context?key={{context_case_id}}-locked"
    Then the response status must be "200"

    And I set "Authorization" header to "Bearer {{{access_token}}}"

    When I make a DELETE request to "/node/context?key={{context_case_id}}-shared"
    Then the response status must be "200"

    When I make a DELETE request to "/node/context?key={{context_case_id}}-locked"
    Then the response status must be "200"

    When I make a DELETE request to "/node/context?key={{context_case_id}}-node-secret"
    Then the response status must be "200"

  @context-report @ipfs
  Scenario: Include the frozen context IPFS URL in the execution report
    Given I store an uuid in "context_case_id"

    When I make a POST request to "/context"
    """
    {
      "key": "{{context_case_id}}-report",
      "value": "{{context_case_id}}"
    }
    """
    Then the response status must be "200"

    When I make a POST request to "/execute_feature/"
    """
    {
      "feature": "Feature: Context report proof\n  Scenario: Publish context proof\n    Given I wait \"0\" seconds",
      "concurrency": 1,
      "stream": false
    }
    """
    Then the response status must be one of "200,202"
    Then the response must contain text "context_ipfs_hash"
    Then the response must contain text "context_ipfs_url"
    Then the response must contain text "ipfs"

    When I make a DELETE request to "/context?key={{context_case_id}}-report"
    Then the response status must be "200"
