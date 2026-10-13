Feature: Track productive vs distracting X11 time by app and title
  As a developer
  I want DamageBDD to verify my focus time
  So that I can enforce habits and guard-rails

  Background:
    Given I start x11 time tracker
    And I alias x11 app focus to classes "Emacs, jetbrains-idea, Code"
    And I alias x11 app video to classes "mpv, firefox, Chromium"

  Scenario: Morning discipline
    When I reset x11 time usage
    And I wait "3600" seconds
    Then x11 time for alias focus should be at least 45m
    And x11 time for alias video should be under 5m
    And I print x11 usage summary

  Scenario: Cap YouTube doomscrolling
    Then x11 time for class firefox should be under 1h
