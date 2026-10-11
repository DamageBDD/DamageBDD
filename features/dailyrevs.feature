Feature: Test DailyRevs
  Scenario: Test landing page
    Given I am using server "https://dailyrevs.com"
    And I set "Content-Type" header to "application/x-yaml"
    When I make a GET request to "/"
    Then the response status must be "200"
  Scenario: Test landing page www
    Given I am using server "https://www.dailyrevs.com"
    And I set "Content-Type" header to "application/x-yaml"
    When I make a GET request to "/"
    Then the response status must be "200"
  Scenario: Test landing page in browser
    Given the page url is not "https://dailyrevs.com"
    And I open the url "https://dailyrevs.com"
    Then I expect that the url is "https://dailyrevs.com"
    And I expect that the url is not "http://google.com"
    When I click on the link "two"
    Then I expect that the title is "two"
