Feature: Phase 2B C crypto backend boundary

  Scenario: C backend can generate and reopen an encrypted vault
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And the Phase 2B test vault path is "/tmp/damage-nsecbunker-phase2b-c-bdd.vault"
    And the Phase 2B test vault is reset
    And the Phase 2B test vault passphrase is "phase2b-c-bdd-passphrase"
    When I ask the crypto backend to generate identity
    Then the crypto backend response MUST be ok
    And the crypto backend result field "pubkey_hex" MUST be present
    And the returned public key MUST be 64 lowercase hex characters
    When I ask the crypto backend for the public key
    Then the crypto backend response MUST be ok
    And the crypto backend result field "pubkey_hex" MUST be present

  Scenario: C backend can sign an event through the port contract
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And the Phase 2B test vault path is "/tmp/damage-nsecbunker-phase2b-c-bdd.vault"
    And the Phase 2B test vault is reset
    And the Phase 2B test vault passphrase is "phase2b-c-bdd-passphrase"
    When I ask the crypto backend to generate identity
    Then the crypto backend response MUST be ok
    When I ask the crypto backend for the public key
    Then the crypto backend response MUST be ok
    When I ask the crypto backend to sign a kind 1 event
    Then the crypto backend response MUST be ok
    And the signed event MUST contain id and sig
    And the crypto backend response MUST NOT contain secret material

  Scenario: C backend supports Phase 2B plain NIP44 loopback only when enabled
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And the Phase 2B test vault path is "/tmp/damage-nsecbunker-phase2b-c-bdd.vault"
    And the Phase 2B test vault passphrase is "phase2b-c-bdd-passphrase"
    And Phase 2B plain NIP44 loopback is enabled
    When I ask the crypto backend to encrypt a Phase 2B plaintext response
    Then the crypto backend response MUST be ok
    When I ask the crypto backend to decrypt the Phase 2B ciphertext response
    Then the crypto backend response MUST be ok
    And the decrypted plaintext MUST equal the encrypted plaintext
