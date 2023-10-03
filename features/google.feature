Feature: Test basic functionality of Google.com using HTTP API

  Scenario: GET request to Google.com
    Given I am using server "http://localhost:8080"
    And I set "Accept" header to "application/json"
    And I set "Content-Type" header to "application/json"
    Given I store an uuid in "testuuid"
    When I make a GET request to "/?test"
    Then the response status must be "200"
