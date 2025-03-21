Feature: Auth features 
  Scenario: Login and get auth token 
    Given I am using server "https://run.staging.damagebdd.com"
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
