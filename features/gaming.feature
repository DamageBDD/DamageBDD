@archlinux @nvidia3090 @5800X3D @damagebdd
Feature: Peak gaming on Arch Linux for Ryzen 7 5800X3D + NVIDIA RTX 3090
  As a player of Insurgency: Sandstorm
  I want my Arch system tuned for low frametime variance and high FPS
  So that my competitive sessions stay smooth and responsive

  # Optional: set a working directory if your runner expects it
  # Given I change directory to /tmp

  Scenario: One-shot peak gaming setup and verified launch
    When I install core gaming packages
    And I enable gaming services
    And I set CPU governor to performance
    And I set NVIDIA persistence mode on
    And I prefer maximum performance on the GPU
    And I configure GameMode defaults
    And I configure MangoHUD frametime view
    And I disable the compositor while gaming (KDE)
    And I raise user limits for gaming tools
    Then service gamemoded.service should be active
    And service nvidia-persistenced.service should be active
    And the NVIDIA PowerMizer mode should be 1
    When I launch Insurgency Sandstorm with overlays
    Then the exit status must be 0
