Feature: Arch Linux AUR eBPF vulnerability check with live affected list

  Scenario: Fetch latest affected list, store it on IPFS, then verify host
    Given the Arch AUR audit window starts at "2026-06-11"
    And the affected AUR package list URL is "https://md.archlinux.org/s/SxbqukK6IA"

    When I fetch the latest affected AUR package list and store IPFS hash in "affected_list_cid"
    And I collect Arch AUR eBPF vulnerability evidence

    Then no known affected AUR package is installed
    And no Atomic Arch IOC appears in AUR build files
    And no Atomic Arch IOC appears in npm or bun caches
    And no suspicious systemd persistence is present
    And no suspicious eBPF artifact is present
    And unprivileged BPF loading is disabled
    And the Arch AUR eBPF vulnerability check passes
