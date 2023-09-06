Feature: For testing an echo server running on localhost
  Scenario: root
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/echo/read_body"
    """
    {"status" : "ok"}
    """
    Then the json at path "$.status" must be "ok"
