Feature: Node Defence baseline
  Background:
    Given I use sudo is true

  Scenario: Harden SSH and firewall
    Then iptables chain INPUT must exist
    Then SSH must disallow password auth
    Then sysctl key net.ipv4.ip_forward must be 0
    Then fail2ban must have jail sshd

    When I append iptables rule "-p tcp --dport 22 -j DROP -m comment --comment DamageBDD" to chain INPUT
    When I set sshd_config PasswordAuthentication to no and reload
