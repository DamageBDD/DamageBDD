Feature: Test DamageBDD Scheduling API
  Scenario: Post feature data
    Given I am using server "https://run.dev.damagebdd.com"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    And I set "Content-Type" header to "x-www-form-urlencoded"
    When I make a POST request to "/schedules/once/60/secs"
    """
    Feature: For testing schedule post
       Scenario: root
         Given I am using server "https://run.dev.damagebdd.com"
         And I set "Authorization" header to "Bearer {{{access_token}}}"
         When I make a GET request to "/"
         Then the response status must be "200"
    
    """
    Then I print the response
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    When I make a GET request to "/schedule/"
    Then the json at path "$[0].id" 

