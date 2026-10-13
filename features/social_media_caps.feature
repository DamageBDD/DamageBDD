Feature: Cap social media by browser + window title (generic)
  Background:
    Given I start herbstluftwm event monitor
    And I start x11 time tracker

  # Firefox example (unchanged behaviour)
  Scenario: Keep YouTube under control in Firefox
    When I reset x11 time usage
    And I wait "2000" seconds
    Then x11 time for firefox titles matching "youtube|ytmusic" should be under 20m
    And notify if x11 time for firefox titles matching "youtube|ytmusic" exceeds 20m with "⏳ YouTube budget blown"

  # Chromium example
  Scenario: Limit Twitter and Reddit in Chromium
    When I reset x11 time usage
    And I wait "2500" seconds
    Then x11 time for Chromium titles matching "twitter|x\\.com" should be under 15m
    And x11 time for Chromium titles matching "reddit" should be under 10m
    And notify if x11 time for Chromium titles matching "twitter|x\\.com|reddit" exceeds 20m with "🚫 Social doomscrolling detected"

  # Brave example (class often "Brave-browser")
  Scenario: Cap Instagram in Brave
    When I reset x11 time usage
    And I wait "1800" seconds
    Then x11 time for Brave-browser titles matching "instagram" should be under 10m
    And notify if x11 time for Brave-browser titles matching "instagram" exceeds 10m with "📵 IG break time"
