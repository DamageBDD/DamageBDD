# Original AWS bunker handoff

Implementation delivery: 25 October 2026. Patch baseline: the uploaded
`latest-damage.tar.gz` application snapshot dated 14 October 2026. This is an
implementation and local validation delivery, not a claim that the live LodgeiT
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
{nsecbunker_admin_origin, <<"https://lightning.lodgeit.org">>}
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

1. Open Nostr bunker and select **Check health**. Resolve every failed required
   control. Compare the pinned signing public key against the handover record.
2. With the AWS administrator, prepare a distinct AWSPENDING version containing
   the existing approved unlock value, using the established secret-management
   procedure. Do not put secret values in CLI arguments, logs or evidence fields.
3. Select **Check pending version** and retain the passing version ID. This opens
   an isolated encrypted-vault copy; it does not change AWS labels.
4. The AWS administrator promotes that exact version to AWSCURRENT. The
   read-only bunker does not perform the promotion.
5. Select **Verify current version & restore**. This verifies fresh retrieval,
   encrypted-vault restore, identity, diagnostic signing, incorrect-unlock
   rejection and the opaque DETS snapshot restore.
6. During the agreed maintenance window, select **Restart & verify**. The live
   signer is briefly unavailable. This action repeats the relay/policy checks
   after a fresh bootstrap. Keep the diagnostic client's rate budget available;
   probes are paced and the real rate limiter stays enabled.
7. Obtain/retain Andrew's independent external-client acceptance and the AWS
   administrator's effective-permissions/removal evidence. Confirm the recovery
   custodian and actual retained backup. These are separate from the node's
   diagnostic-client results.
8. In Operator acceptance, enter all four evidence references. They are labelled
   **operator-attested**, not independently verified IAM or external-client facts.
   Acceptance is bound to the current verification report hash and rechecks the
   running configuration/process immediately before recording it.
9. Export the evidence bundle. Optionally execute
   `priv/features/nsecbunker/handoff-acceptance.feature` through the existing
   DamageBDD runner to produce the normal BDD acceptance report. Its assertions
   are read-only; feature text cannot invoke maintenance or create signoff.

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
