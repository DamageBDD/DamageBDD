@ecai @math @isogeny @source_only
Feature: Source-only mathematical exploration with replayable evidence
  Give ECAI one rational curve, not a preselected destination.
  Isogenous curves need not be Q-isomorphic; equal j is not enough.
  A bounded search is not a claim of globally new mathematics or completeness.

  Scenario: Discover non-isomorphic reachable models without supplying a target
    Given the source-only mathematical exploration seed
    When I explore from the mathematical source without a target
    Then the exploration has four rational isomorphism classes
    And every retained exploration path replays successfully
    And every retained source-isomorphism certificate rechecks successfully

  Scenario: Keep checked evidence when the model budget is exhausted
    Given the source-only mathematical exploration seed
    When I explore with a two-model mathematical budget
    Then the exploration retains two checked models and reports its limit
    And every retained exploration path replays successfully
    And every retained source-isomorphism certificate rechecks successfully
