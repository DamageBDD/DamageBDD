Feature: Dashboard feature
As a developer
I should be able to use given text snippets

Scenario: open URL
    Given the page url is not "https://run.damagebdd.com/"
    And   I open the url "https://run.damagebdd.com/"
    Then  I expect that the url is "https://run.damagebdd.com/"
    And   I expect that the url is not "http://google.com"


Scenario: click on login
    Given the title is not "two"
    And   I open the url "http://webdriverjs.christian-bromann.com/"
    When  I click on the link "two"
    Then  I expect that the title is "two"
