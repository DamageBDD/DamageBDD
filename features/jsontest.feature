Feature: Test echo json functionality of JsonTest.com using HTTP API

  Scenario: GET request to JsonTest.com
    Given I am using server "http://echo.jsontest.com"
    When I make a GET request to "/key/value/one/two"
    Then the json at path "$.one" must be "two"

