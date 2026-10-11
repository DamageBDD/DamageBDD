Feature: Directory Syncing Across Multiple Nodes Using Syncthing

  As a systems administrator
  I want to ensure specific directories are kept in sync across nodes
  So that all nodes have access to the same, up-to-date files

  Background:
    Given Syncthing is running
    And the Syncthing REST API is accessible

  Scenario: Add and verify new directories to be synced across nodes
    Given I add the directory "/shared/media" to the sync configuration
    And I share the directory "/shared/media" between nodes "node1" and "node3"
    When I request the sync status for "/shared/media" from "node1"
    Then the sync status for "/shared/media" on "node1" should be "up-to-date"
    And the sync status for "/shared/media" on "node3" should also be "up-to-date"

  Scenario: Verify sync status after modifications
    Given directory "/shared/documents" is defined in the sync configuration
    And the directory "/shared/documents" is shared between nodes "node1" and "node2"
    When I modify a file in "/shared/documents" on "node1"
    Then the sync status for "/shared/documents" on "node2" should change to "syncing"
    And eventually, the sync status for "/shared/documents" on both "node1" and "node2" should be "up-to-date"
