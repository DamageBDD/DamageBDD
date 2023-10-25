Feature: Check for open ports

  Scenario: Port scan host
    Given I am using server "localhost"
    When I request a port scan
    Then the json at path "$.num_open" must be "0"
