Feature: Windows packages via Chocolatey, verified by DamageBDD
  In order to bootstrap a Windows dev box quickly
  As a team that values deterministic, repeatable setups
  I want to install and verify packages using Chocolatey steps through DamageBDD

  Background:
    Given I am the node named "win-runner-01"
    And I allow chocolatey packages "git, 7zip"

  @provision
  Scenario: Ensure Chocolatey is present
    Given Chocolatey is available
    Then the last choco exit status must be "0"

  @provision
  Scenario: Install Git and verify version
    Given Chocolatey is available
    When I choco install "git"
    Then the last choco exit status must be "0"
    And the choco package "git" should be installed
    And the choco package "git" version should be ">=2.47.0"

  @upgrade
  Scenario: Upgrade Git if present
    Given Chocolatey is available
    When I choco upgrade "git"
    Then the last choco exit status must be "0"
    And the choco package "git" should be installed

  @cleanup
  Scenario: Uninstall Git cleanly
    Given Chocolatey is available
    When I choco uninstall "git"
    Then the last choco exit status must be "0"
