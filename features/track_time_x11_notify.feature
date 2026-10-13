Feature: Desktop notifications when time limits are exceeded
  As a user
  I want DamageBDD to notify me if I overuse an app
  So that I can react immediately and stay on track

  Background:
    Given I start herbstluftwm event monitor
    And I start x11 time tracker
    And I alias x11 app video to classes "firefox, Chromium"

  Scenario: Warn when Firefox exceeds 30 minutes
    When I reset x11 time usage
    And I wait "1900" seconds
    Then notify if x11 time for class firefox exceeds 30m with "⚠️ Too much Firefox already!"

  Scenario: Warn when total video exceeds 1 hour
    Then notify if x11 time for alias video exceeds 1h with "⚠️ Video time budget blown!"
