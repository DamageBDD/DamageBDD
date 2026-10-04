Feature: Bootstrap a knots node with verification

  Scenario: Download, verify, and extract Bitcoin Knots (example)
    When I download file from "https://github.com/dathonohm/bitcoin/releases/download/v29.3.knots20260210%2Bbip110-v0.3/bitcoin-29.3.knots20260210+bip110-v0.3-aarch64-linux-gnu.tar.gz" to "knots.tgz" as "knots_tgz"
    Then the checksum sha256 of "$knots_tgz" must be "sha256:7757ad4cc61c1729b4ad8613597e8578563d6197f2b808a8831f1a392e50ff39"
    Given I import gpg key from url "https://github.com/dathonohm/guix.sigs/blob/bip110/29.3.knots20260210%2Bbip110-v0.3/bitcoinmechanic/noncodesigned.SHA256SUMS.asc"
    When I download file from "https://github.com/dathonohm/bitcoin/releases/download/v29.3.knots20260210%2Bbip110-v0.3/SHA256SUMS.asc" to "knots.asc" as "knots_sig"
    Then the signature at "$knots_sig" verifies for "$knots_tgz"
    When I extract archive "$knots_tgz" to "/opt/bitcoin" with strip-components "1"
