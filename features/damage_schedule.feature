Feature: Test DamageBDD Scheduling API

  Scenario: Schedule a one-shot feature using the legacy secs alias
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
    Then the response status must be "201"
    Then the json at path "$.status" must be "ok"

    When I make a GET request to "/schedules/"
    Then the response status must be "200"
    Then the json at path "$.status" must be "ok"
    Then I print the response

  Scenario: Schedule a daily PM feature using the legacy am/pm token format
    Given I am using server "https://run.dev.damagebdd.com"
    And I set "Authorization" header to "Bearer {{{access_token}}}"
    And I set "Content-Type" header to "x-www-form-urlencoded"
    When I make a POST request to "/schedules/daily/every/3/0/pm"
    """
    Feature: For testing daily schedule post
      Scenario: root
        Given I am using server "https://run.dev.damagebdd.com"
        When I make a GET request to "/version/"
        Then the response status must be "200"
    """
    Then the response status must be "201"
    Then the json at path "$.status" must be "ok"
