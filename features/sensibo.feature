Feature: Sensibo API Client

  Background:
    Given I am using server "https://home.sensibo.com/api/v2"
    And secret "SENSIBO_API_KEY" is provided

  Scenario: Retrieve list of devices
    When I send a "GET" request to "/users/me/pods" with parameters:
      | apiKey  | {{MY_API_KEY}} |
      | fields  | id,room    |
    Then the response status should be 200
    And the response body should contain a list of devices
    And each device should have "id" and "room.name"

  Scenario: Get pod measurements
    Given a device "Living Room" with pod ID "POD_UID"
    When I send a "GET" request to "/pods/POD_UID/measurements" with parameters:
      | apiKey  | {{MY_API_KEY}} |
    Then the response status should be 200
    And the response body should contain measurement data

  Scenario: Get AC state of a pod
    Given a device "Living Room" with pod ID "POD_UID"
    When I send a "GET" request to "/pods/POD_UID/acStates" with parameters:
      | apiKey  | {{MY_API_KEY}} |
      | limit   | 1          |
      | fields  | acState    |
    Then the response status should be 200
    And the response body should contain the latest "acState"

  Scenario: Change AC state of a pod
    Given a device "Living Room" with pod ID "POD_UID"
    And the current AC state is:
      | on | true |
    When I send a "PATCH" request to "/pods/POD_UID/acStates/on" with parameters:
      | apiKey  | {{MY_API_KEY}} |
      | body    | {"currentAcState": {"on": true}, "newValue": false} |
    Then the response status should be 200
    And the AC state should be updated to:
      | on | false |
