Feature: Auth features 
  Scenario: Login and get auth token 
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/auth/"
    """
    {
        "grant_type": "password",
        "scope": "basic",
        "username": "{{{damage_username}}}",
        "password": "{{{damage_password}}}"
    }
    """
    Then the response status must be "200"
    Then I store the JSON at path "$.access_token" in "access_token"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
  Scenario: Set account context
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    When I make a POST request to "/context/"
    """
    {
        "name":"example_context_variable",
        "value":"non redaacted",
        "secret": false
    }
    """
    Then I print the response
    Then the response status must be "202"
#
#  Scenario: Test redacted values in reporting
#    Given I am using server "http://localhost:8080"
#    And I set "Content-Type" header to "application/json"
#    When I make a POST request to "/test/echo/"
#    """
#    Example context variable: {{{example_context_variable}}}
#    Example context variable redacted: {{{example_context_variable_redacted}}}
#    """
#    Then the response status must be "200"

    
