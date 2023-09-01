Feature: Localhost server
  Scenario: root
    When I make a GET request to "/"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
