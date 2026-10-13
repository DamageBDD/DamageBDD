Feature: DamageBDD bid endpoint

  Background:
    Given I notify "fail" to "discord" webhook
    Given I am using server "https://run.staging.damagebdd.com"
    And I set "Content-Type" header to "application/x-yaml"

  Scenario: Publish testcase
    When I make a POST request to "/bid_feature/"
    """
feature_hash: Qmc7rhECtJLKNvb9ZfjXQhszLGz97XHjeK8H7oGMEQxwAZ
bid: 100
    """
    Then the response status must be "201"
    Then the json at path "$.status" must be "ok"

  Scenario: list bids
    When I make a GET request to "/bids/"
    Then the response status must be "200"
    Then the json at path "$[0].id" must be "ok"
