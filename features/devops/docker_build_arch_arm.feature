# PACMAN_DISABLE_SANDBOX=1 opts out of pacman download isolation for this build only.
# Build-only check: does not package DamageBDD or mint a release NFT.
Feature: Verify the PinePhone Pro ARM64 builder
  Scenario: Build and validate the ARM64 native toolchain
    When I build an image from Dockerfile at "Qme2zQxE18bXrzNYE6zJYAY7kH8vC9myCHzbcDvnHbqRSR" as tag "damagebdd/arch-builder-pinephone:latest" with params "--platform linux/arm64 --build-arg 'PACMAN_DISABLE_SANDBOX=1' --build-arg 'REPO_URL=https://github.com/DamageBDD/DamageBDD.git' --build-arg 'REPO_REF=develop'"
    Then I run docker image tagged "damagebdd/arch-builder-pinephone:latest"
    """
    set -eu
    test "$(uname -m)" = aarch64
    damage-builder-check
    printf '%s\n' '[damagebdd] PinePhone Pro ARM64 builder verified'
    """
