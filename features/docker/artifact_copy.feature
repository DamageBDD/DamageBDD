Feature: Docker artifact copy to IPFS

  Scenario: Copy generated Arch package from exited Docker container to IPFS
    Then I run docker image tagged "damagebdd/arch-builder:latest"
      """
      set -ex

      cd /app
      mkdir -p /app/_build/pkg/arch/damage

      echo "damage test artifact" > /app/_build/pkg/arch/damage/test-artifact.txt
      tar --zstd -cf /app/_build/pkg/arch/damage/test-artifact.pkg.tar.zst \
        -C /app/_build/pkg/arch/damage test-artifact.txt

      echo "artifact created"
      """

    Then I copy file "/app/_build/pkg/arch/damage/" from the container to ipfs and store the hash in "asset_hash"
