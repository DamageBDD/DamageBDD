Feature: For testing an login sequence
  Background: 
  Scenario: login
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/accounts/signup"
    """
    {"username" : "testuser",
    "password": "test_password"}
    """
    Then the json at path "$.status" must be "ok"
    When I make a POST request to "/accounts/login"
    """
    {"username" : "testuser",
    "password": "test_password"}
    """
    Then the json at path "$.status" must be "ok"
    When I make a POST request to "/accounts/profile"
    Then the json at path "$.username" must be "testuser"

  Scenario: login bad password
    When I make a GET request to "/"
    Then the response status must be "200"
    When I make a POST request to "/accounts/signup"
    """
    {"username" : "testuser",
    "password": "test_wrongPassword"}
    """
    Then the json at path "$.status" must be "failed"
