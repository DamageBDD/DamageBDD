Feature: Mobile header layout does not overflow and buttons remain aligned

  Scenario: Header is aligned on a mobile viewport (Chrome Android class)
    Given I attach CDP
    And I set viewport to "390" x "844"
    When I open "https://run.dev.damagebdd.com/"
    And I wait for "[data-testid='header']"

    Then the page should have no horizontal overflow within 1 px
    And the element "[data-testid='header']" should be within the viewport horizontally

    # Button pixel-parity + alignment (you already have these)
    And the element "[data-testid='header-install']" should be the same size as "[data-testid='header-logout']" within 1 px
    And the text of element "[data-testid='header-install']" should be visually centered within 1 px
    And the text of element "[data-testid='header-logout']" should be visually centered within 1 px
    And the elements "[data-testid='header-install']" and "[data-testid='header-logout']" should be vertically aligned at center within 1 px
