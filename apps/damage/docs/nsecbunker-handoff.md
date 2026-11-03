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

## Compact operator interface

The top health bar shows the last check time and a separate **Check health**
button. Handover below it shows one short task. **You** is implicit; **AWS admin**
is shown when a separate administrator must act. Only one health action appears
in the default view when the next task is the initial health check.

**View commands** previews the exact current command block beside its copy button.
**Help** opens the relevant detail. **Advanced details** contains manual controls,
configuration and evidence. **Sign-off** opens the four reference fields inline,
without opening diagnostics. **Sign off** still refreshes health, rechecks the
reviewed report and requires backend eligibility before recording acceptance.

Button labels **Test prepared version**, **Test recovery**, **Restart and test**
and **Download report** map to the same existing actions. No eligibility rule,
AWS command, permission, confirmation or evidence requirement changed. Failures
retain their corrective guidance; historical acceptance retains its qualifications.

## Operator closing sequence

The default view presents **one next action**, its owner and recorded status.
Use **Checks, commands and evidence** for diagnostics or manual controls. Guide
links open the relevant detail automatically; the dashboard route stays intact.

1. **Operator preparation:** health, relay signing and the four evidence references.
2. **One AWS administrator session:** copy/run prepare, check pending, copy/run
   promotion. Keep the administrator present between these two CLI operations.
   Remove temporary access and retain its reference after the AWS work.
3. **Operator closeout:** verify current/restore, restart and verify, review the
   references, submit acceptance, and export the recorded evidence.

The next action uses recorded server evidence. Copying commands only changes the
on-screen suggestion; it does not record completion. After a page reload,
**Already prepared? Check pending** and **Already promoted? Verify restore** resume
external work without recreating a version. No maintenance starts on page load,
copy, tab navigation or polling. Restore/restart/pending confirmations remain.

A successful restart already supplies fresh signing evidence. Matching maintenance
reports use the stable target across restart; the old pending fingerprint need
not equal the restarted process fingerprint. An observed promotion with expired,
replaced or non-distinct pending evidence goes to version reconciliation, never an
automatic repeat of the pending check.

**Refresh health & record acceptance** is one explicit submission. It refreshes
health, waits for the result, checks that the reviewed signing-report hash is
unchanged and that the server still permits acceptance, then submits the four
operator declarations. It stops on any error; it never silently retries acceptance
or runs other maintenance. If a maintenance report changes while a confirmation
is open, review the updated evidence before confirming again.

Existing acceptance is displayed as a retained record. Only current server closure
with a matching report is labelled accepted; historical acceptance never asserts
current health. A fresh health check remains available without redoing handover.

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

Use **Setup → AWS custody and runtime access** to set the separate administrator
profile in a Bash shell with AWS CLI v2, jq and Python 3:

```bash
export BUNKER_ADMIN_PROFILE='your-admin-profile'
```

Each expandable AWS CLI block has a **Copy** button. Commands are generated from
the displayed account, region, secret and role; inspect them against the approved
record. Copying never makes an API mutation or runs AWS. Use the same agreed
maintenance window and coordinate other writers/rotation.

| Who | Command or dashboard action | Continue when |
| --- | --- | --- |
| Operator | **Check health**, then **Verify signing** | Required controls and every relay pass. |
| AWS administrator | **Setup → Copy inspection commands** | Account, full secret ARN, version labels and role policy references agree with the approved record. |
| AWS administrator | **Recovery & handover → Prepare → Copy prepare commands**; paste and run in Bash | Output shows distinct baseline and pending IDs. |
| Operator | **Check pending version** | Passed; recorded baseline/pending IDs match the command output. |
| AWS administrator | **Promote → Copy promotion commands**; run promptly | AWSCURRENT is on the exact tested ID. Retain the change/audit reference. |
| Operator | **Verify current version & restore**, then **Restart & verify** | Both pass; restored/restarted IDs match the tested version. |
| Operator/reviewers | Review the four references; **Refresh health & record acceptance**, **Export evidence** | Acceptance is recorded and its exported report is retained with the references. |

**Prepare** pipes the existing nonempty SecretString from `get-secret-value`
through jq into `put-secret-value --cli-input-json file:///dev/stdin`. It preserves
the full string, including newlines. It disables AWS CLI history for the selected
profile first. Keep debug logging off; do not add `tee`, print the pipeline or
record secret-bearing command responses. No secret is put in shell arguments,
temporary files, this page or evidence.

The new version starts with a unique `HANDOFF-<UUID>` label. The command attaches
AWSPENDING with `update-secret-version-stage` without `--remove-from-version-id`,
so it fails if another version already holds that label, then removes only its
own HANDOFF label. It stops for enabled automatic rotation or existing pending
work. On error, inspect versions and reconcile before retrying; a HANDOFF version
may remain. It does not move AWSCURRENT, generate a new passphrase or rekey a vault.

**Promote** is available only after a passing pending rehearsal, with current
passing health and matching target/fingerprint. It embeds the baseline and tested
version IDs from the report, rechecks their AWS labels, then runs:

```bash
aws --profile "$BUNKER_ADMIN_PROFILE" --region "$BUNKER_REGION" \
  secretsmanager update-secret-version-stage --secret-id "$BUNKER_ARN" \
  --version-stage AWSCURRENT --move-to-version-id "$BUNKER_TESTED" \
  --remove-from-version-id "$BUNKER_BASELINE"
```

This excerpt illustrates the mutation; copy the complete dashboard block for its
configured region, exact IDs and guards. Never substitute whichever version AWS
happens to label pending. The block checks the rehearsal's 24-hour expiry at
execution time; keep the administrator host clock correct. It cannot re-observe
the running deployment, so run it promptly and recopy after a fresh health check
if delayed. It is not an AWS lock; keep the coordinated maintenance window. A mismatched current label
causes the conditional promotion to fail. **Do not rerun Check pending version
after promotion**; preserve its passing result and continue to restore/restart.

Inspection commands list role and resource policy references; they do not prove
effective IAM permissions. Review policy contents, KMS access and applicable
boundaries/session/organisation controls before recording IAM acceptance. Remove
only the identified temporary grants through the approved access process; these
commands do not guess which administrator principal should be removed.

The restore test deletes its isolated copies. Retain a separate encrypted backup
and custody record. Restart briefly interrupts signing and also records fresh
signing evidence. Acceptance submission refreshes health (60-second window);
signing evidence must be within 15 minutes, maintenance evidence within 24 hours,
for the same deployment. All backend closure and authorisation checks still apply.

AWS command references: [PutSecretValue](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/put-secret-value.html),
[UpdateSecretVersionStage](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/update-secret-version-stage.html),
[CLI data protection](https://docs.aws.amazon.com/cli/latest/userguide/data-protection.html).

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
