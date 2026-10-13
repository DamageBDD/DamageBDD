Scenario: Install curl and verify it
  Given I run apt update
  And I install apt package "curl"
  Then the apt package "curl" must be installed
