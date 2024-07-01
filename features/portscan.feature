Feature: Check for open ports
  Given I notifiy failures to webhook "https://discord.com/api/webhooks/1236841971570577418/9fDR8KAJmaBwll283KFz1iyoYK18rHrUgTCyU2tIjqssrjgZNvzV1jeJgFRqk-bqSxEm"

  Scenario: Port scan host
    Given I am using server "localhost"
    When I request a port scan
    Then the json at path "$.num_open" must be "0"
