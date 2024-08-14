Feature: Test DamageBDD Scheduling API
  Scenario: Post feature data
    Given I am using server "http://localhost:8080"
    When I make a GET request to "/execute_feature/"
    Then the response status must be "200"
    And I set "Content-Type" header to "x-www-form-urlencoded"
    When I make a POST request to "/schedule/once/60/"
    """
    Feature: For testing an request to google
       Scenario: root
       When I make a GET request to "/"
       Then the response status must be "200"
    
    """
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    When I make a GET request to "/schedule/"
    Then the json at path "$[0].id" 

