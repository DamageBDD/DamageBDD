Feature: Verify functionality of damagebdd http interface
  Scenario: Post bdd file via json rest
    When I make a POST request to "/"
  Scenario: Post bdd file via http form
    When I make a POST request to "/"
