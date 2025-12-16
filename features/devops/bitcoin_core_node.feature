Feature: Bootstrap a bitcoin core node

  Scenario: Download, verify, and extract Bitcoin core
    When I download file from "https://bitcoin.org/bin/bitcoin-core-28.1/bitcoin-28.1-x86_64-linux-gnu.tar.gz" to "/tmp/bitcoincore.tgz" as "bitcoin_core_tgz"
    Then the checksum sha256 of "bitcoin_core_tgz" must be "deadbeef...hex..."
    Given I import gpg key from url "https://bitcoinknots.org/ryanofsky.asc"
    When I download file from "https://bitcoin.org/bin/bitcoin-core-28.1/SHA256SUMS.asc" to "/tmp/bitcoincore.asc" as "bitcoin_core_sig"
    Then the signature at "bitcoin_core_sig" verifies for "bitcoin_core_tgz"
    When I extract archive "bitcoin_core_tgz" to "/opt/bitcoin" with strip-components "1"
