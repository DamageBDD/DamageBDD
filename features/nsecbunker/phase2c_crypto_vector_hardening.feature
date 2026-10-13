Feature: Phase 2C crypto vector hardening
  Phase 2C proves crypto semantics before any LodgeiT key ceremony.
  Phase 2B proved the backend boundary; Phase 2C proves BIP340, NIP01,
  NIP19, vault failure modes, and real NIP44 v2 behaviour.

  Scenario: C backend passes BIP340 Schnorr vector 0
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    When I ask the crypto backend to sign BIP340 vector 0
    Then the crypto backend response MUST be ok
    And the crypto backend result field "pubkey_hex" MUST equal "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    And the crypto backend result field "signature_hex" MUST equal "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"
    When I ask the crypto backend to verify BIP340 vector 0
    Then the crypto backend response MUST be ok
    And the crypto backend result field "valid" MUST equal "true"

  Scenario: C backend passes npub and NIP01 event id vectors
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    When I ask the crypto backend to encode the secp256k1 generator npub vector
    Then the crypto backend response MUST be ok
    And the crypto backend result field "npub" MUST equal "npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d"
    When I ask the crypto backend to calculate the NIP01 event id vector
    Then the crypto backend response MUST be ok
    And the crypto backend result field "id" MUST equal "5a25a8422478717a983475e3ab77edeb1b72775dde3d2e2dffb054aa98c5cc45"

  Scenario: C backend passes NIP44 v2 vector 0
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    When I ask the crypto backend to encrypt NIP44 vector 0
    Then the crypto backend response MUST be ok
    And the crypto backend result field "conversation_key" MUST equal "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
    And the crypto backend result field "payload" MUST equal "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
    When I ask the crypto backend to decrypt NIP44 vector 0
    Then the crypto backend response MUST be ok
    And the crypto backend result field "plaintext" MUST equal "a"

  Scenario: C backend performs real NIP44 roundtrip through vault key
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And the Phase 2B test vault path is "/tmp/damage-nsecbunker-phase2c-bdd.vault"
    And the Phase 2B test vault is reset
    And the Phase 2B test vault passphrase is "phase2c-bdd-passphrase"
    And Phase 2C real NIP44 mode is expected
    When I ask the crypto backend to generate identity
    Then the crypto backend response MUST be ok
    When I ask the crypto backend to encrypt a Phase 2C real NIP44 message
    Then the crypto backend response MUST be ok
    When I ask the crypto backend to decrypt the Phase 2C real NIP44 message
    Then the crypto backend response MUST be ok
    And the decrypted plaintext MUST equal the encrypted plaintext

  Scenario: C backend fails closed on wrong vault passphrase
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And the Phase 2B test vault path is "/tmp/damage-nsecbunker-phase2c-bdd.vault"
    And the Phase 2B test vault is reset
    And the Phase 2B test vault passphrase is "phase2c-bdd-passphrase"
    When I ask the crypto backend to generate identity
    Then the crypto backend response MUST be ok
    When I ask the crypto backend to open the vault with the wrong passphrase
    Then the crypto backend result field "error" MUST equal "vault_decrypt_failed"

  Scenario: C backend blocks plain NIP44 in production mode
    Given the Phase 2B crypto backend command is "/opt/damage/bin/damage-nsecbunker-crypto-c"
    And Phase 2B plain NIP44 loopback is enabled
    And Phase 2C production mode is enabled
    When I ask the crypto backend whether plain NIP44 is allowed
    Then the crypto backend response MUST be ok
    And the crypto backend result field "plain_allowed" MUST equal "false"
