Feature: Zap payout for Nostr posts

  # This feature exercises:
  #  - list posts in last N hours
  #  - zap posts in a variable with base/cap and state tracking
  #  - zap all posts by npub since a date (the new step)

  Scenario: List posts and zap them with state tracking
    Then I list nostr posts for npub "npub1EXAMPLEAUTHOR..." in last "24" hours store as "posts"
    """
    {
      "nsec_key": "damage_nostr_nsec",
      "limit": 200
    }
    """

    Then I zap posts in "posts" base sats "21" cap sats "10000" store state as "payout_state_out" store receipts as "zap_receipts"
    """
    {
      "nsec_key": "damage_nostr_nsec"
    }
    """

  Scenario: Zap all posts by npub since a date (single-step payout)
    Then I zap all posts by npub "npub1EXAMPLEAUTHOR..." since "2026-02-01" base sats "21" cap sats "10000" store state as "payout_state_out2" store receipts as "zap_receipts2"
    """
    {
      "nsec_key": "damage_nostr_nsec",
      "limit": 500
    }
    """

  Scenario: Zap all posts by npub since a unix timestamp with explicit state input
    # This shows the stateful variant (continue paying across runs without exceeding the cap per event id).
    Then I zap all posts by npub "npub1EXAMPLEAUTHOR..." since "1700000000" base sats "21" cap sats "10000"
      using state "payout_state_out2" store state as "payout_state_out3" store receipts as "zap_receipts3"
    """
    {
      "nsec_key": "damage_nostr_nsec",
      "limit": 500
    }
    """
