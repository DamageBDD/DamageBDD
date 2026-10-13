Feature: Open endel player and play

Scenario: open and play
    Given the page url is not "https://app.endel.io/player/deeper"
    And   I open the url "https://app.endel.io/player/deeper"
    Then  I expect that the url is "https://app.endel.io/player/deeper"
    When  I click on the button with id "player_pause"
    Then  the  attribute "title" of "button[player_pause]" must be "Pause Soundscape"
