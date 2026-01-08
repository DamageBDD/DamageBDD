Feature: Topbar button sizing

  Scenario: Logout and Install Node buttons match size
    Given I attach CDP
    When I open "https://run.dev.damagebdd.com"
    When I wait for "#installBtn"
    When I wait for "#logoutBtn"
    Then the element "#installBtn" should be the same size as "#logoutBtn" within "1.0" px
    
    Then the text of element "#installBtn" should be visually centered within "1.0" px
    Then the text of element "#logoutBtn" should be visually centered within "1.0" px

    Then the elements "#installBtn" and "#logoutBtn" should be vertically aligned at "center" within "1.0" px
    Then the elements "#installBtn" and "#logoutBtn" should be horizontally aligned at "center" within "1.0" px
