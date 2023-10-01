Feature: Test Gooogle
  Scenario: Do get
    Given I am using server "http://localhost:8080"
    And I set base URL to "/"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    When I make a GET request to "/"
    Then the response status must be "200"
