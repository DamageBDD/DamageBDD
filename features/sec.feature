Feature: My hardening features
  Background:
    Given I am authenticated with "rapid7" service
  Scenario:
    Given I am using server "fe_node000"
    When I request a port scan in range "0-max"
    Then the json at path "$.num_open" must be "0"
