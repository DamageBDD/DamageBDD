Feature: System Hardening and User Setup

  Scenario: Disable root login
    Given a fresh Arch Linux installation
    When I lock the root account password
    Then the root user should not be able to log in

  Scenario: Create a non-root user with sudo access
    Given a fresh Arch Linux installation
    When I create a user "damage" with a home directory
    And I add "damage" to the "wheel" group
    And I enable sudo for the "wheel" group
    Then "damage" should be able to run sudo commands

  Scenario: Harden SSH configuration
    Given an SSH server is installed
    When I disable root login in "sshd_config"
    And I disable password authentication in "sshd_config"
    Then SSH should reject root login attempts
    And SSH should require key-based authentication

  Scenario: Restrict kernel logs and process visibility
    Given a running Arch Linux system
    When I set "kernel.dmesg_restrict = 1"
    And I set "kernel.randomize_va_space = 2"
    And I set "kernel.yama.ptrace_scope = 2"
    And I set "kernel.unprivileged_userns_clone = 0"
    Then unprivileged users should not access kernel logs
    And ASLR should be enabled
    And process IDs should be hidden from unprivileged users
    And user namespace creation should be restricted

  Scenario: Enable essential security services
    Given an Arch Linux system
    When I enable "sshd"
    And I enable "systemd-timesyncd"
    Then the system should synchronize time securely
    And the SSH service should be available on startup
