Feature: Ensure availability of damagebdd system services
  Scenario: ensure riak servers are available
    Given I am using server "http://threadripper0.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"
    Given I am using server "http://doombox.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"
    Given I am using server "http://zenbook.lan:8098"
    When I make a GET request to "/ping"
    Then the response status must be "200"

  Scenario: ensure IPFS servers are available
    Given I am using server "http://threadripper0.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"
    Given I am using server "http://doombox.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"
    Given I am using server "http://zenbook.lan:8082"
    When I make a POST request to "/version"
    Then the response status must be "200"
