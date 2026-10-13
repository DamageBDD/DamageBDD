@web @jumia @search
Feature: Jumia Nigeria site search
  As a shopper on Jumia Nigeria
  I want to search for products from the homepage
  So that I can find relevant items quickly
  # NOTE:
  # - These scenarios assume you have steps for filling inputs, clicking, pressing keys,
  #   waiting for visibility, and URL/content assertions in your DamageBDD step library.
  # - If not, keep Scenario 1 and implement the minimal extra steps you need.

  Background:
    Given I open the url "https://www.jumia.com.ng"

  @smoke
  Scenario: Basic search for a common product
    Given I wait until the element "css=input[name='q']" is visible
    When I clear the field "css=input[name='q']"
    And I type "laptop" into the field "css=input[name='q']"
    And I press "Enter" in the field "css=input[name='q']"
    Then I wait until the url contains "q=laptop"
    And I expect at least 1 element matching "css=section.-paxs > article, css=.prd, css=[data-test='product']" to be visible
    And I expect the page to contain text "laptop" (case-insensitive)

  @regression
  Scenario: Search via the search button
    Given I wait until the element "css=input[name='q']" is visible
    When I type "iphone 13" into the field "css=input[name='q']"
    And I click the element "css=button[type='submit'], css=button.-mls, css=button[data-test='search-btn']"
    Then I wait until the url contains "q=iphone%2013"
    And I expect the page to contain text "iPhone 13"

  @ux @suggestions
  Scenario: Suggestions appear while typing (non-blocking, may be flaky)
    Given I wait until the element "css=input[name='q']" is visible
    When I type "sams" into the field "css=input[name='q']"
    Then I expect the element "css=[role='listbox'], css=.srg, css=.sug" to be visible
    And I expect at least 1 element matching "css=[role='option']" to be visible

  @negative
  Scenario: Empty search is handled gracefully
    Given I wait until the element "css=input[name='q']" is visible
    When I clear the field "css=input[name='q']"
    And I press "Enter" in the field "css=input[name='q']"
    Then I expect either:
     | condition                                |
     | the url remains "https://www.jumia.com.ng" |
     | or the page shows a validation message    |
     | or the search box is focused              |

  @deeplink
  Scenario Outline: Results page deep-link loads correctly
    When I open the url "https://www.jumia.com.ng/catalog/?q=<term>"
    Then I wait until the url contains "q=<url-encoded-term>"
    And I expect at least 1 element matching "css=section.-paxs > article, css=.prd, css=[data-test='product']" to be visible

    Examples:
     | term        | url-encoded-term |
     | ps5         | ps5              |
     | samsung tv  | samsung%20tv     |
     | air fryer   | air%20fryer      |

  @perf
  Scenario: Search results render within acceptable time
    Given I wait until the element "css=input[name='q']" is visible
    When I start timing "search-results"
    And I type "headphones" into the field "css=input[name='q']"
    And I press "Enter" in the field "css=input[name='q']"
    Then I wait until the element "css=section.-paxs, css=.products, css=#productsListing" is visible within 10000 ms
    And I stop timing "search-results"
    And I expect the recorded time for "search-results" to be less than 8000 ms
