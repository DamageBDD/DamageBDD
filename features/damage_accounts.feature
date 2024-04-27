Feature: Customer account management for DamageBDD
    @wip
  Scenario: User account creation and kyc for billing use of DamageBDD yaml endpoint
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/x-yaml"
    When I make a POST request to "/accounts/create"
    """
---
customer_type: "Individual"
full_name: "John Doe"
email: "john.doe@damagebdd.com"
    """
    Then the response status must be "201"
    Then I print the response
    Then the yaml at path "$.status" must be "ok"

  Scenario: User account creation and kyc for billing use of DamageBDD json endpoint
    Given I am using server "http://localhost:8080"
    Given I am using smtp server "smtp.damagebdd.com"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/accounts/create"
    """
    {
        "customer_type": "Individual",
        "full_name": "John Doe",
        "email": "john.doe@damagebdd.com",
    }
    """
    Then the response status must be "201"
    Then the yaml at path "$.status" must be "ok"
    Then "john.doe@damagebdd.com" must have received a email in "1 minute" with content
    """
Hello
    """
