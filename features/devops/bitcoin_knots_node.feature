Feature: Bootstrap a knots node with verification

  Scenario: Download, verify, and extract Bitcoin Knots (example)
    When I download file from "https://bitcoinknots.org/files/29.x/.../bitcoin-29.2.knots20251010-{{arch}}-linux-gnu.tar.gz" to "/tmp/knots.tgz" as "knots_tgz"
    Then the checksum sha256 of "$knots_tgz" must be "deadbeef...hex..."
    Given I import gpg key from url "https://bitcoinknots.org/ryanofsky.asc"
    When I download file from "https://bitcoinknots.org/files/29.x/.../bitcoin-29.2.knots20251010-{{arch}}-linux-gnu.tar.gz.asc" to "/tmp/knots.tgz.asc" as "knots_sig"
    Then the signature at "$knots_sig" verifies for "$knots_tgz"
    When I extract archive "$knots_tgz" to "/opt/bitcoin" with strip-components "1"
