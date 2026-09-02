Feature: X.Org strict security verification
  DamageBDD verifies the active Xorg/Xwayland runtime and host policy without
  changing the machine or reading Xauthority cookie contents.

  Scenario: Active Xorg satisfies the strict security profile
    Given I audit the active Xorg server
    Then Xorg should satisfy the strict security profile
    And I print the Xorg security audit

  # To audit a specific display instead:
  # Given I audit Xorg display ":0"
  #
  # If the display manager's -auth path is not visible in /proc:
  # Given I use Xorg authority file "/run/user/1000/gdm/Xauthority"
  # Given I audit Xorg display ":0"
  # Then Xorg should satisfy the strict security profile
