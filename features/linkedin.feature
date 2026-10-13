Feature: Test basic functionality of linkedin oauth api

  Scenario: GET request to linkedin
    Given I am using server "https://www.linkedin.com"
    When I make a GET request to "/search?q=bdd"
    Then the response must contain text "behaviour driven development"
