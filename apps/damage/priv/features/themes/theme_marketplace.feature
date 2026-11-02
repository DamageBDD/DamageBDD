Feature: Portable DamageBDD theme marketplace
  Background:
    Given I am using server "https://damagebdd.com"

  Scenario: A node publicly advertises its NFT theme catalog
    When I make a GET request to "/api/themes"
    Then the response status must be "200"
    Then the response must contain text "AEX-141"

  Scenario: A compatible stylesheet is available for the dashboard
    When I make a GET request to "/api/themes/css?app=damage"
    Then the response status must be "200"
    Then the response must contain text "--damage-accent:"

  Scenario: ECAI and Nosternity use the same validated theme variables
    When I make a GET request to "/api/themes/css?app=ecai"
    Then the response status must be "200"
    Then the response must contain text "--damage-surface:"
    When I make a GET request to "/api/themes/css?app=nosternity"
    Then the response status must be "200"

  Scenario: Unknown applications cannot request arbitrary CSS
    When I make a GET request to "/api/themes/css?app=not-a-real-app"
    Then the response status must be "400"
