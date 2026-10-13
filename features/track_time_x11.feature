Feature: Track productive vs distracting X11 time by app and title
  As a developer using DamageBDD on X11
  I want to verify time spent in apps with BDD
  So that I can enforce habits and avoid time sinks

  Background:
    # boot the hlwm event monitor (already exists in steps_herbstluftwm)
    Given I start herbstluftwm event monitor
    # start the X11 time tracker (new)
    And I start x11 time tracker
    # group multiple WM classes under convenient aliases
    And I alias x11 app focus to classes "Emacs, jetbrains-idea, Code"
    And I alias x11 app video to classes "mpv, firefox, Chromium"
    And I alias x11 app chat to classes "TelegramDesktop, Slack, discord"

  @morning
  Scenario: Morning discipline (1h session)
    When I reset x11 time usage
    # ... you do your thing for ~1 hour; this can be run by scheduler at 10:00
    And I wait "3600" seconds
    Then x11 time for alias focus should be at least 45m
    And x11 time for alias video should be under 5m
    And I print x11 usage summary

  @evening
  Scenario: Cap doomscrolling after work
    When I reset x11 time usage
    # scheduler can run this between 20:00–23:00
    And I wait "1800" seconds
    Then x11 time for class firefox should be under 20m
    And x11 time for alias chat should be under 10m
    And I print x11 usage summary

  @daily
  Scenario: Daily budget check (aggregate caps)
    # no reset here—let tracker accumulate all day; run at 23:55
    Then x11 time for alias focus should be at least 2h
    And x11 time for alias video should be under 45m
    And x11 time for class Emacs should be at least 1h
    And I print x11 usage summary
