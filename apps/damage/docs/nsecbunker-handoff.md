# Original AWS bunker handoff

Implementation delivery: 25 October 2026. Patch baseline: the uploaded
`latest-damage.tar.gz` application snapshot dated 14 October 2026. This is an
implementation and local validation delivery, not a claim that a live
instance has passed the new checks.

## Scope

The node-admin dashboard has a **Nostr bunker** page with Overview, Setup,
Evidence and Recovery & handover views. Setup reads the deployed configuration
and guides the operator; configuration is applied through the existing approved
release process. The page never accepts an nsec or vault passphrase and does not
provision infrastructure or generate/replace an identity.

The controller records these original-handoff checks:

- Production AWS custody; an existing vault; pinned signing public key; absent
  local `nsecbunker_vault_passphrase` entry; private vault/audit files.
- Secret retrieval provenance: expected account/EC2 role, IMDSv2, the agreed
  secret identifier hash and AWSCURRENT.
- Separate relay round trips for ping, get_public_key, allowed kind 30023,
  forbidden method and forbidden event kind, using the existing authorised
  `damage_nostr` diagnostic identity. Explicit WSS relays are required (maximum
  six). The workflow never adds this client automatically.
- Canonical event IDs and actual BIP-340 signature checks on the request,
  response and signed article, exact requested article equality, recipient tags,
  request IDs and correlated decision/completion audit records.
- A real non-allowlisted local diagnostic request is rejected. A separate policy
  rehearsal checks rejection after removing the diagnostic client's permission;
  the live allowlist is not changed by this rehearsal.
- Cold restart of the bunker subtree followed by fresh AWS bootstrap and relay
  checks. The controller is supervised outside that subtree.
- Encrypted-vault copy/restore, unchanged public identity, a verified diagnostic
  signature, and rejection of a deliberately incorrect unlock value. The live
  vault is never replaced.
- An opaque logical DETS snapshot is restored into a separate private file and
  compared record-for-record, without decrypting or reporting its records. The
  restored snapshot must also lack the local bunker-passphrase entry. The live
  table is not replaced or closed. This is a logical snapshot rehearsal, not a
  claim that all concurrent application writes were transactionally frozen.
- AWSPENDING-to-AWSCURRENT **version-stage rehearsal**, with distinct version IDs,
  preserved identity, observed promotion of the exact tested version, and fresh
  service bootstrap using that version.

The stage rehearsal uses the existing unlock value. It does not implement a new
vault format, change the actual encryption passphrase, rewrap the production
vault or replace the Nostr identity. Actual vault rekey/identity rotation remains
outside this delivery's original scope.

## Apply and validate

From the existing DamageBDD repository root:

```sh
git apply --check ~/Downloads/damagebdd-bunker-handoff.patch &&
git apply ~/Downloads/damagebdd-bunker-handoff.patch
rebar3 compile
rebar3 eunit --module=damage_nsecbunker_handoff_tests,damage_aws_secret_provider_tests,damage_nsecbunker_config_tests,damage_nsecbunker_policy_tests,damage_nsecbunker_phase2_contract_tests,damage_nsecbunker_phase3_relay_tests
```

The ZIP also contains the patch, changed source files under `overlay/`, and local
validation results. Prefer applying the patch; the overlay is for review or a
manual merge. Do not overwrite newer application files blindly. If patch context
has diverged, rebase these changes against that source before deployment.

Build/deploy with the repository's existing release process. The application
registers the new routes and controller; the standard application `priv` assets
contain the UI, CSS, feature and templates. Full release assembly must be checked
in the complete umbrella repository: the supplied baseline contains only the
Damage application.

The dashboard URL is `/dashboard#node-bunker-tab`. The API is
`/api/admin/bunker`. Authenticated node-admin authority is required on every
request; wallet-only sessions are denied. POST requires JSON, a same-origin
request and `X-Damage-Bunker-Action: 1`. Bearer-authenticated CLI requests may
omit Origin but still require that custom header. No CORS permission is added.

Behind TLS termination, configure the exact public origin through the existing
application configuration when Cowboy cannot observe it directly:

```erlang
{nsecbunker_admin_origin, <<"https://bunker.example.com">>}
```

The signer keeps its existing read-only access to the agreed Secrets Manager
ARN. No IAM mutation/introspection permission is added. Existing customer-managed
KMS encryption may also require its narrowly scoped Decrypt permission. A
version-stage restriction can make AWSPENDING verification fail; it is surfaced
as a failure, never silently bypassed or broadened.

Ensure the existing vault and audit log are regular private files owned by the
service account. Audit directories must exist and the audit log must be writable.
Audit writes are now synchronized and fail closed: failure to record a decision
prevents signing; failure to record completion prevents returning that response.

## Operator closing sequence

### Prepare the handover

Open `/dashboard#node-bunker-tab` with node-admin authority. Have the approved
deployment record, independently recorded signing public key, maintenance
window, AWS administrator and external-client operator available. The AWS
administrator uses separate authorised credentials for version creation and
promotion; do not give those write permissions to the bunker runtime role.

In **Setup**, compare the region, account, secret identifier, EC2 role and signing
public key with the approved record. Confirm one to six explicit WSS relays and
the approved clients/policy. The diagnostic client must already be authorised.
Apply any correction through the normal release process before starting the
rehearsal. Configuration is not edited on this page.

Prepare the four acceptance evidence references below before the final health
check. Coordinate secret-version changes so another administrator or rotation
job does not change the version under test during this sequence.

### Run the checks in order

1. **Operator — check health and initial signing.** Select **Check health**, open
   **Overview**, and resolve each failed control. Then select **Verify signing**
   and inspect **Evidence**: each configured relay must pass its diagnostic
   probes. A configured relay is never silently skipped. Preserve the approved
   signing identity throughout this workflow.
2. **AWS administrator — prepare a distinct pending version.** In the configured
   account and region, use [ListSecretVersionIds](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/list-secret-version-ids.html)
   for the agreed secret and record the current `AWSCURRENT` version ID. Use the
   approved secret-handling procedure and [PutSecretValue](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/put-secret-value.html)
   with that secret identifier, a new UUID as `ClientRequestToken`, and
   `VersionStages` explicitly set to `["AWSPENDING"]`. Supply the **existing
   approved unlock value**, unchanged. Omitting the stage can move `AWSCURRENT`
   prematurely. Do not enter the value in this dashboard, evidence references,
   command history or logs. Record the new pending version ID and verify it is
   different from current. This is a version-stage rehearsal, not a rekey.
3. **Operator — test pending before promotion.** In **Recovery & handover**,
   select **Check pending version**, review the confirmation and proceed. Wait
   for a passing result. Retain its `version_id` and `baseline_version_id` from
   the displayed evidence or export; in exported JSON they are under
   `evidence.pending.recovery.secret_provenance`. These must match the new
   pending version and the old current version respectively. The check opens
   an isolated encrypted-vault copy and does not change AWS labels. If it fails,
   resolve the cause before promotion.
4. **AWS administrator — promote exactly the tested version.** Recheck the
   version labels against the retained IDs; stop if another change has occurred.
   Use [UpdateSecretVersionStage](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/update-secret-version-stage.html)
   with the agreed `SecretId`, `VersionStage=AWSCURRENT`,
   `MoveToVersionId` equal to the passing pending `version_id`, and
   `RemoveFromVersionId` equal to its recorded `baseline_version_id`. Use
   ListSecretVersionIds again to confirm `AWSCURRENT` is on that exact tested
   version. Retain the change/audit reference. The bunker performs no promotion.
   **Do not rerun Check pending version after promotion:** it would replace the
   earlier result and can no longer prove the pending version was distinct from
   current. Continue with restore verification.
5. **Operator — verify current version and restore.** Select **Verify current
   version & restore** and confirm. Require a passing result and confirm
   `evidence.recovery.recovery.secret_provenance.version_id` equals the retained
   tested pending ID. This check freshly retrieves current, restores an isolated
   encrypted-vault copy and opaque DETS snapshot, checks identity and diagnostic
   signing, and rejects an incorrect unlock value. It never replaces the live
   vault. The temporary copies are deleted: **this rehearsal does not create a
   retained recovery backup**. Confirm the separately retained backup and its
   custodian through the recovery evidence reference.
6. **Operator — restart and verify.** During the agreed maintenance window,
   select **Restart & verify**, review the interruption warning and proceed.
   Wait for a passing result. This briefly interrupts the live signer, performs
   fresh AWS bootstrap using the promoted version, and repeats all relay and
   policy probes. It also records fresh live-signing evidence; an immediate
   separate Verify signing run is unnecessary. Keep the diagnostic client's
   rate budget available; the real rate limiter remains enabled.
7. **Operators — complete independent acceptance evidence.** Run the approved
   external client's smoke test against the pinned identity, retain its result,
   and complete the IAM, temporary-access-removal and retained-backup evidence
   described below. The external-client result is separate from this page's
   diagnostic client. Remove temporary administrative access only after the
   administrator has completed the required AWS work.
8. **Operator — refresh and record acceptance.** Enter all four evidence
   references. If live-signing evidence is older than 15 minutes, select
   **Verify signing** again. Then select **Check health**, wait for it to pass,
   and record acceptance within 60 seconds. The technical Closing checklist
   rows must all pass and the acceptance button must be enabled. Select
   **Record handover acceptance**. Acceptance is bound to the current
   verification report hash and rechecks the running configuration/process
   immediately before recording. If blocked, follow the linked failed/stale
   requirement and refresh health again after resolving it.
9. **Operator — retain the completed record.** Confirm the Handover summary
   shows **accepted**, an acceptance actor is recorded, and the operator
   acceptance row is **operator attested**. Select **Export evidence** after
   acceptance and attach the JSON plus the referenced records to the handover
   ticket. Retain the signing report hash with that independent record. Optionally
   run `priv/features/nsecbunker/handoff-acceptance.feature` through the existing
   DamageBDD runner for its BDD acceptance report. Its assertions only read
   evidence; they cannot invoke maintenance or create signoff.

### What to put in the four acceptance fields

Each entry is a reference to an existing reviewed record, not a credential or
an assertion manufactured by the dashboard. Use 8–256 ASCII characters: letters,
digits, spaces and `. _ : / # @ -`. Query strings, `nsec1` and AWS access-key
prefixes are rejected. Use a ticket or document identifier when its full URL
contains unsupported characters. The examples below are placeholders to replace
with actual evidence.

| Field | Supporting record must identify | Example reference |
| --- | --- | --- |
| Effective IAM permissions reviewed | Reviewer, review time, deployed account/role and agreed secret; effective access including applicable policies and KMS access. Use the [AWS IAM policy guidance](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_iam-policies.html). The dashboard's provenance check does not audit effective IAM permissions. | `IAM-REVIEW-2026-001` |
| Temporary administrator access removed | Temporary grant or principal, who removed it, removal time and supporting access-review/audit record after the AWS work. | `CHANGE-2026-001/admin-removal` |
| External client accepted | Approved client public key, pinned signer key, test time, tested operation and independently verified result accepted by its operator. | `ACCEPTANCE-2026-001/client-test` |
| Recovery custodian and retained backup confirmed | Named custodian, protected backup inventory/version and retention/access/recovery record for the actual retained backup. The dashboard's temporary restore copy is not that backup. | `RECOVERY-2026-001/backup-register` |

If pending/restore evidence expires, is replaced, or no longer matches the
deployment, coordinate a new distinct pending version and repeat the ordered
rehearsal. Do not promote an untested version or rerun pending against the
already-promoted version to try to clear the checklist. A restore or restart
failure should be resolved through the approved incident/recovery procedure;
the dashboard does not perform AWS rollback or vault replacement.

The Closing checklist identifies each missing requirement and its next action.
A green historical report alone cannot close the handover. Health expires after
60 seconds, live signing after 15 minutes, and maintenance evidence after 24 hours.
Configuration, code, backend-artifact, encrypted-vault, process or retrieved-secret
version changes invalidate affected current evidence. On controller startup,
previous health is cleared and recollected; a previous process's readiness is
not restored as current health. The historical handover acceptance remains
available separately (`handover_status`); expiring operational observations do
not erase that acceptance or require daily secret-version rehearsals. `closure`
describes eligibility against the current evidence for recording a new acceptance.

For subsequent operation, **Check health** reads status and controls;
**Verify signing** signs only fixed diagnostics through the authorised client.
Restart/restore/pending checks are separate explicit maintenance actions. GET does
not sign, restart, add clients or access pending versions. Controller startup
performs an observation-only health check. Only one maintenance/verification job
runs at a time. Its worker is linked/monitored, has a deadline, and cannot outlive
the controller. AWS bootstrap ownership is serialized with maintenance retrieval.

## Evidence and verification

Decision audit rows retain schema 1. New schema-2 completion rows contain only
public correlation metadata: request ID, requester/signing public keys, method,
decision and request/response/signed-event IDs. They contain neither ciphertext
nor plaintext request bodies. The exported diagnostic proof can include the
public encrypted relay envelopes and the signed diagnostic article; it never
includes either private key or the AWS value.

The controller stores public evidence below the configured bunker state
folder in `handoff/`, with a private directory and files. Each report has a
canonical JSON SHA-256; hash-named JSON archives are created exclusively and
never overwritten. A private state index retains the latest observations and
operator declarations. Keep exported report hashes with the independent handover
record. This is tamper-evident local evidence, not an assertion of immutable
storage against a privileged host attacker.

On a separate trusted DamageBDD installation with the existing signature
verification dependency available:

```erlang
damage_nsecbunker_handoff:verify_export("/path/to/bunker-handoff-evidence.json").
```

This verifies report hashes, public event signatures and matching audit IDs.
It cannot independently attest current IAM permissions, host integrity, actual
external-client use or offsite backup custody. The operator references retain
that distinction. NIP-46 signing also does not establish control of an unrelated
Bitcoin address or contract; the proposed asset-disclosure pilot is not included.

## UI validation

The browser test uses mocked API data to validate UI behaviour, not live bunker
operation. With Playwright available in Node's module resolution:

```sh
node --test apps/damage/test/scripts/bunker_admin_browser.test.mjs
```

Install a Playwright Chromium browser for the test, or set
`BUNKER_TEST_CHROMIUM=/absolute/path/to/chromium`. It covers opening the page
without side effects, action headers, maintenance cancellation/confirmation,
text escaping, mobile overflow and failure-state acceptance disabling.
