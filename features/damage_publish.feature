Feature: DamageBDD publish endpoint

  Background:
    Given I notify "fail" to "discord" webhook
    Given I am using server "https://run.staging.damagebdd.com"
    And I set "Content-Type" header to "application/x-yaml"

  Scenario: Publish testcase
    When I make a POST request to "/publish_feature/"
    """
concurrency: 2
schedule: ['daily', ['every', [23, 'sec'], ['between', [3, 'pm'], [3, 30, 'pm']]]]
feature_data: |
    Feature: For testing an request to google
       Scenario: root
       When I make a GET request to "/"
       Then the response status must be "200"
    """
    Then the response status must be "201"
    Then the json at path "$.status" must be "ok"

  Scenario: list published testcase
    When I make a GET request to "/publish_feature/"
    Then the response status must be "200"
    Then the json at path "$[0].id" must be "ok"
