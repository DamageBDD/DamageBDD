Feature: Test the expected behaviour of abr gov website.
  Scenario: Verify json functionality
    Given I am using server "https://abr.business.gov.au"
    When I make a GET request to "/json/"
    Then the json at path "$a"
