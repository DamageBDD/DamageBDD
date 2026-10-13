@api @context @node-auth @node-authz-negative
Feature: Scoped context node authorization
  A valid authenticated account that is not listed in damage.node_admins
  cannot mutate node-level context.

  # Run this feature separately with access_token belonging to an account that
  # is valid for /context but is not present in damage.node_admins.
  Background:
    Given I am using server "{{{api_url}}}"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{access_token}}}"

  Scenario: Reject an authenticated account outside node_admins
    Given I store an uuid in "context_case_id"

    # This proves authentication succeeded before node authorization is tested.
    When I make a GET request to "/context"
    Then the response status must be "200"

    When I make a POST request to "/node/context"
    """
    {
      "key": "{{context_case_id}}-denied",
      "value": "must-not-be-written",
      "inheritance": "default",
      "exposure": "template"
    }
    """
    Then the response status must be "401"
