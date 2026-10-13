Feature: Generic SELinux checks

  Scenario: Status check
    When I query selinux status
    Then selinux status must be "Enforcing"

  Scenario: User confinement
    When I collect process selinux labels
    Then processes of user "damage" must be in selinux domain containing "damage_t"

  Scenario: Build template
    When I write a selinux policy template for "damage" to "/tmp/damage.te"
    When I build selinux module from te at "/tmp/damage.te"

