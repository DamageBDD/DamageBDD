Feature: DamageBDD Market Making

  Background:
    Given I am using server "https://run.staging.damagebdd.com"
    And I set "Content-Type" header to "application/json"
    And I set "Authorization" header to "Bearer {{{access_token}}}"

  Scenario: Publish testcase
    When I make a GET request to "/publish_feature"
    Then the response status must be "200"
    When I make a POST request to "/publish_feature"
    """
    fee_rate: 1
    concurrency: 2
    pool_size: 2
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

  Scenario: Bid on testcase
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
