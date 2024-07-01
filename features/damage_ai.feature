Feature: Damage AI gen
  Scenario: Generate bdd from user story
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/ai/generate/"
    """
    {
        "model": "damage_bddgen",
        "prompt": "generate bdd for oauth cookie based login an selenium session"
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"

  Scenario: Generate python code from bdd
    Given I am using server "http://localhost:8080"
    And I set "Content-Type" header to "application/json"
    When I make a POST request to "/ai/generate/"
    """
    {
        "model": "damage_codegen",
        "prompt": "generate bdd for oauth cookie based login an selenium session"
    }
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
