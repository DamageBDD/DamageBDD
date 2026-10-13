Feature: Basic Nostr Relay WebSocket Behaviour

  Background:
    Given I am using server "wss://relay.example.com"

  Scenario: Relay accepts WebSocket connection
    When I connect to websocket
    Then the connection should be open

  Scenario: Relay accepts REQ and responds with NOTICE
    When I connect to websocket
    And I send websocket message '["REQ", "sub_id", {"kinds":[1]}]'
    Then I receive websocket message matching regex '\["NOTICE",.*\]'

  Scenario: Relay responds with EVENT to REQ
    When I connect to websocket
    And I send websocket message '["REQ", "sub_id", {"kinds":[1]}]'
    Then I receive websocket message matching regex '\["EVENT",.*\]'

  Scenario: Relay accepts CLOSE
    When I connect to websocket
    And I send websocket message '["CLOSE", "sub_id"]'
    Then I receive websocket message matching regex '\["EOSE", "sub_id"\]'

  Scenario: Relay handles invalid message gracefully
    When I connect to websocket
    And I send websocket message '["FOO", "sub_id"]'
    Then I receive websocket message matching regex '\["NOTICE",.*invalid.*\]'
