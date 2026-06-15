Feature: Arch Linux AUR eBPF vulnerability check

  Scenario: Host is clean from the Atomic Arch AUR/eBPF compromise path
    Given the Arch AUR audit window starts at "2026-06-11"
    And the affected AUR package list file is "/var/tmp/affected-aur-packages.txt"
    When I collect Arch AUR eBPF vulnerability evidence
    Then no known affected AUR package is installed
    And no Atomic Arch IOC appears in AUR build files
    And no Atomic Arch IOC appears in npm or bun caches
    And no suspicious systemd persistence is present
    And no suspicious eBPF artifact is present
    And unprivileged BPF loading is disabled
    And the Arch AUR eBPF vulnerability check passes
