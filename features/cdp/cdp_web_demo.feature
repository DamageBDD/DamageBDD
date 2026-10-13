@cdp @web @popular
Feature: Demo steps against popular websites
  These scenarios use real sites that are relatively stable.
  Make sure a DevTools-enabled browser is running (e.g. chrome --headless=new --remote-debugging-port=9222)

  Background:
    Given I attach CDP

  @example
  Scenario: Open Example.com and verify text
    When I open "https://example.com/"
    When I wait for "body > div:nth-child(1) > h1:nth-child(1)"
    When I wait until the page contains "Example Domain"
    Then the page should contain "Example Domain"

  @search @duckduckgo
  Scenario: DuckDuckGo search
    When I open "https://duckduckgo.com/"
    When I wait for "input[id=searchbox_input]"
    When I type "erlang cdp" into "input[id=searchbox_input]"
    When I press "Enter"
    Then the page should contain "erlang"

  @wiki
  Scenario: Wikipedia search and open a result
    When I open "https://www.wikipedia.org/"
    When I wait for "input[name=search]"
    When I type "Erlang" into "input[name=search]"
    When I press "Enter"
    Then the page should contain "Erlang"

  @hn
  Scenario: Hacker News – open and click Login
    When I open "https://news.ycombinator.com/"
    Then the page should contain "Hacker News"
    When I click text "login"
    Then the page should contain "login"
