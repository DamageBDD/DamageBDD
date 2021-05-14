@sanity
Feature: Install
    In order to create BDD tests
    Developers
    want to use Cucumber like tests for Bravo Delta
  Background:
    When I make a CSRF form POST request to "/accounts/signup/"
    """
    {
        "username": "{{login_username}}",
        "password1": "{{login_password}}",
        "password2": "{{login_password}}",
        "role": "Developer",
        "number_users": "250,000+",
        "first_name": "Delete",
        "last_name" : "Me",
        "company_name": "Streethawk",
        "phone": "023203203",
        "terms": true
    }
    """
    Then I print the response
    When I make a CSRF form POST request to "/accounts/login/"
      """
      {
      "login": "{{login_username}}",
      "password": "{{login_password}}"
      }
      """
    Then the response status must be "200"
    Given I store cookies
    Given I set "Content-Type" header to "application/json"
    When I make a POST request to "/v3/apps"
    """
    {
        "company_name": "Streethawk",
        "app_key": "DeleteMe{{timestamp}}",
        "country": "AU",
        "product": "pointzi"
    }
    """
    Then I print the response
    Then the response status must be "201"
    When I make a GET request to "v3/apps/access/?app_key={{app_key}}"

@wip  
Scenario: Web Page1
    When I make a GET request to "/v3/debug"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
  

@wip  
Scenario: Web Page2
    When I make a GET request to "/v3/debug"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
