Feature: ECAI Video Fastpath customer proof-of-value
  ECAI signs recoverable video references and avoids unnecessary provider calls.

  Scenario: Import customer's existing video without AI generation
    Given a customer has a valid ECAI workspace key
    And a 2 second MP4 produced by their existing workflow
    When they upload the MP4
    Then the original media SHA-256 is recorded
    And the version manifest is signed with the configured secp256k1 key
    And no external video provider is invoked

  Scenario: Change a campaign offer without touching media
    Given an imported video version
    When the customer creates a metadata-only revision
    Then the output video SHA-256 equals the input video SHA-256
    And the revision has a parent relationship to the original
    And generation and re-encoding are skipped
    And signature and local video integrity verification pass

  Scenario: Change visible text without regenerating AI video
    Given an imported video version
    When a caption is applied by the local FFmpeg backend
    Then the new version has a different video SHA-256
    And the original AI provider is not called again
    And signed lineage connects the original and changed versions

  Scenario: Fail closed on forged metadata or mutated bytes
    Given a verified version
    When a signed manifest field is tampered with
    Then signature verification fails
    When the MP4 bytes are tampered with
    Then video content verification fails

  Scenario: Don't double-bill after a crash during provider submission
    Given a provider job was marked as submitting
    When the service restarts before recording a remote request ID
    Then the job enters needs_review instead of silently submitting again

  Scenario: Prepare NFT handoff only after local integrity checks
    Given a verified ECAI video revision
    When a customer supplies a video CID
    Then the service creates an NFT metadata draft with that CID
    But it does not claim that minting or IPFS publication was verified
