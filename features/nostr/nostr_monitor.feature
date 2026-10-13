Feature: Nostr monitor stays alive

  Scenario: Monitor a npub and process notes until stopped
    Given I start a nostr monitor for "npub1..." on relay "wss://nos.lol" as "nostr_mon"

    Then I wait for the next nostr note from monitor "nostr_mon" and store event as "note_event"
    Then I store the nostr event content from "note_event" in "note_content"

    Given I stop the nostr monitor "nostr_mon"
