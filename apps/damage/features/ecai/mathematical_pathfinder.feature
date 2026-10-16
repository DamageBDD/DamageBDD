@ecai @math @isogeny
Feature: Replayable mathematical paths
  ECAI finds paths between exact mathematical objects and checks every map.
  A lookup, a signature, or a submitted verification flag is not a proof.

  Scenario: Compose two explicit degree-2 maps
    Given the ECAI mathematical pathfinder demo graph
    When I find the mathematical path
    Then the mathematical path has composite degree "4"
    And every mathematical path step replays successfully

  Scenario: Discover the intermediate curves from a bounded kernel search
    Given the ECAI mathematical pathfinder demo graph
    When I discover the mathematical path
    Then the mathematical path has composite degree "4"
    And every mathematical path step replays successfully
