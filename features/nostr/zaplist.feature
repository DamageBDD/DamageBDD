Feature: Zap payout for Nostr posts
  This feature exercises:
  - list posts in last N hours
  - zap posts in a variable with base/cap and state tracking
  - zap all posts by npub since a date (the new step)

  Background:
    Given I set the variable "damage_contributor_npub" to "npub1azuntqk4e5sgtjaajpu547q5xzrx6xf5aunvm6vq7p793ttaf6hst3etlz"
    Given I set zap limit for npub "{{damage_contributor_npub}}" to 100000 sats

  Scenario: List posts and zap them with state tracking
    Then I list nostr posts for npub "{{damage_contributor_npub}}" in last "24" hours store as "posts"
    Then I zap posts in "posts" base sats "21" cap sats "10000"

  Scenario: Zap all posts by npub since a date (single-step payout)
    Then I list nostr posts for npub "{{damage_contributor_npub}}" since "2026-01-15" store as "posts"
    Then I zap posts in "posts" base sats "21" cap sats "10000"
