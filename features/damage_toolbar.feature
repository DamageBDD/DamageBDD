Feature: Topbar button sizing

  Scenario: Logout and Install Node buttons match size
    Given I attach CDP
    When I open "https://run.dev.damagebdd.com"
    When I wait for "#installBtn"
    When I wait for "#logoutBtn"
    Then the element "#installBtn" should be the same size as "#logoutBtn" within "1.0" px
