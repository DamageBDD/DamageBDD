Feature: For testing an echo server running on localhost
  Scenario: root
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/"
    """
    {"status" : "ok"}
    """
    Then the json at path "$.status" must be "ok"
    When I make a GET request to "/metrics/"
    Then the response status must be "200"
