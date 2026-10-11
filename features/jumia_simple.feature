Feature: Jumia Testing


Scenario: Search somethign on jumia
    Given I open the url "https://www.jumia.com.ng"
    When I enter text "apple" in input field id "fi-q"
    Then I expect that the title contains "Apple Official Store"
