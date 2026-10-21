# Automatic AWS Setup

## Scope and delivery baseline

This subsystem is built against the latest uploaded `latest-ecai.tar.gz`,
SHA-256 `fd10271c62b5ca00304ae61c3bc9c90b7aec0cfbcc647e20081b63767ffbe32c`.
Apply its patch once; it does not depend on reapplying any earlier UI patches.
Existing compute budgets, mint settings, authentication, Google Cloud settings
and the manual AWS provider form are retained.

The shipped path is **Compute → AWS Batch → Automatic setup**:

1. Connect a temporary setup session using AWS credentials and a region.
2. Generate and review an immutable plan. Planning creates no AWS resources.
3. Explicitly authorize creation of the listed resources and IAM roles.
4. Track the CloudFormation stack, import non-secret outputs, and check the
   runtime role independently of the supplied setup credentials.
5. Optionally authorize one chargeable synthetic S3 verification job.

**Infrastructure provisioning is implemented; production remote indexing is
not enabled by this patch.** The uploaded reservation integration remains
`pending`. Its worker-image contract, index-job dispatch, output/artifact import,
accounting reconciliation and real indexing end-to-end acceptance still need
that separate integration. The UI never promotes a successful setup probe to
“ready for indexing.” No live AWS resources were created during development.

## Operator setup (once per node)

The subsystem is disabled by default. Merge the entries in
`priv/config/aws_setup.example.config` into your existing application config;
do not replace your full configuration with that sample.

Required prerequisites:

- A Linux node with Python 3.11+ and the pinned boto3 dependency installed in an
  operator-controlled virtual environment. Both the script tree and environment
  must not be writable by dashboard users.
- An HTTPS public dashboard origin without a path/trailing slash. For TLS
  termination, configure only exact trusted proxy peer IP tuples and keep the
  unencrypted upstream listener private. The proxy must overwrite forwarded
  headers rather than passing arbitrary client values through.
- `compute_aws_coordinator_role_arn`: the precise IAM role for the ECAI node.
  The node must obtain that role's credentials through its normal workload
  identity, independently of every customer's bootstrap key. This patch does
  not provision the node's own federation or Roles Anywhere identity.
- A trusted Linux/X86_64 worker image, pinned as `registry/repository@sha256:`
  plus its full digest, readable from the selected AWS account. No demo image
  or working production remote index image is shipped or silently substituted.
- An approved non-empty worker command list. The dashboard cannot override
  the image, template, IAM policy or command.

Install the helper dependency from the repository root:

```sh
python3 -m venv /opt/ecai/aws-setup-venv
/opt/ecai/aws-setup-venv/bin/pip install \
  -r apps/ecai/priv/aws_setup/requirements.txt
```

Use paths writable/owned by your deployment account as appropriate. Set
`aws_setup_python` to the resulting executable, fill the sample placeholders,
then explicitly enable `aws_setup_enabled`. Initially restrict
`aws_setup_accounts` to your managed test account. An empty list permits every
managed account after the global switch is enabled.

Restart/deploy the ECAI application so the new supervisor and routes are loaded.
Compilation alone does not update a separate running release's `priv` files.
Inspect `code:priv_dir(ecai).` if the dashboard still serves older assets.

### AWS setup identity permissions

The supplied identity must already be authorized to create the approved stack.
A valid access-key pair cannot bypass IAM, organization SCPs, permission
boundaries, service quotas or regional service availability. Root credentials
are explicitly rejected. ASIA temporary keys require their session token.

Have the account administrator review the downloaded template and authorize
its setup identity for the corresponding CloudFormation create/read/delete,
EC2 network, S3 bucket/policy, IAM role/inline-policy, CloudWatch Logs and Batch
resource actions. Role passing must be scoped to the expected ECAI roles.
First-time Batch setup may also require creation of its service-linked role.
No universal administrator policy is automatically attached by this feature;
organization-specific least-privilege bootstrap policy review remains necessary.

No user-supplied CloudFormation execution role is accepted in this version.
CloudFormation uses the submitted identity's authority. The plan viewer is a
local, versioned template preview, **not an AWS change set or permission dry
run**. `GetCallerIdentity` confirms account identity, not provisioning rights.
AWS authorization failures leave a safe error code and a reconcileable record.

## Created environment

The versioned template `ecai-aws-fargate/v1` provisions:

- A dedicated VPC, internet gateway, two public subnets, route table/associations,
  and worker security group with no ingress rules and outbound TCP/443.
- A private, public-access-blocked, AES256-encrypted S3 bucket. A bucket policy
  denies non-TLS access. Runtime and task access is limited to `staging/`.
- Separate coordinator-runtime, ECS execution and worker task roles. Runtime
  trust pins the node's IAM principal and account-specific external ID.
- A Fargate compute environment and job queue. CPU profiles are 1 vCPU/2 GiB
  and 2 vCPU/4 GiB; capacity is limited to selectable 1/2/4/8 total vCPUs.
- An immutable worker job definition and separate synthetic-probe definition.
  Runtime submission permissions reference the exact definition revisions;
  the imported provider connection is also revision-pinned.
- A CloudWatch log group with selectable 7/14/30-day retention.

There is no NAT gateway, public inbound service, GPU profile, custom VPC mode,
key-free quick-create flow, arbitrary template/image upload or automatic stack
update in this initial implementation. These are explicit scope boundaries.

The automatically named stack/resources include a random durable operation ID.
The existing external ID is reused so manual trust setup is not silently
rotated. Generated IAM roles are not granted infrastructure-administration
permissions for ordinary work. Read-only Batch describe/list operations use
service-supported resource scopes; other accesses are restricted by the
resource references/prefixes in the downloadable policy.

Network, storage, logs, public IPv4 and transfer can incur charges even though
an indexing job has not been submitted. Fargate networking/image pull and
cross-account private ECR repository permissions must be valid in the target
account. The worker security group permits only outbound HTTPS; applications
requiring other outbound protocols are not supported by this profile.

## Credential and authentication boundary

Every API route requires the existing managed/custodial account authentication
with an **explicit bearer**, not an ambient session cookie or wallet-only
identity. The backend derives the owner and never accepts an owner ID in the
request. Setup sessions are scoped to both owner and bearer fingerprint. A
new account/token cannot reuse another token's bootstrap session.

Credentials are submitted only to the dedicated setup endpoint over HTTPS.
The browser clears input fields immediately and never stores them in local or
session storage. The new fields are not part of the ordinary provider form.
The isolated Python subprocess receives credentials via a bounded stdin pipe,
not argv, environment variables, temporary files, job specifications or the
ordinary DETS provider store. Explicit boto3 credentials are used for bootstrap;
fixed regional AWS endpoints and no inherited proxy prevent configured endpoint
redirection. Root identities and unknown request fields are rejected.

The long-lived manager and operation records hold no AWS credential map.
Sensitive BEAM processes and formatted status redaction reduce accidental log
exposure; Python core dumps are disabled where supported. Sessions expire after
15 minutes, and terminal deployments discard the attached setup session. The
child watches pipe closure so disconnecting its port terminates it even while
an SDK network call is waiting. A node restart discards all setup sessions.

**Do not enable request-body capture, debug tracing or credential logging in a
reverse proxy, Cowboy middleware, APM or operator instrumentation.** Trusted
same-UID/root access, OS swap and node-wide crash dumps remain an operational
security boundary. Python/BEAM memory copies cannot promise cryptographic
zeroization. This is not protection against a compromised node administrator.

“Discard credentials” removes ECAI's copy; it does not revoke a long-lived AWS
key. Disable/delete that key in AWS when no longer needed, or use naturally
expiring temporary credentials. The node must use its own workload credentials
for post-provisioning verification and assume the new restricted runtime role.

## Durable approval, import and recovery

The service persists its records in `aws_setup.dets`, defaulting to the existing
index state directory, with file mode 0600. Each record is flushed before an
external mutation. It includes account, region, plan/template hashes, operation
ID, stack identity, state, safe events and approval intent—not setup credentials.
There is a limit of four live bootstrap sessions globally, one per account,
eight active setup records per account and 4096 total records. Unused plans may
be discarded locally without touching AWS; audit records are retained.

Plan requests use an idempotency key. Repeating a key with different options is
a conflict. Deploy requires the plan hash, explicit cost/IAM approval and, if a
provider already exists, replacement approval. Operator image/command/region/
coordinator changes prevent deployment of an obsolete plan.

CloudFormation creation uses the fixed stack name and stable client request
token. Retries reconcile the same recorded stack rather than creating another.
Account, region, operation tags, plan hash, original template and expected
output ARNs are checked before import. Out-of-band changes are not silently
adopted. Events omit raw AWS status-reason text; full details remain available
through the first-party AWS console link.

Provider import is a compare-and-swap against the settings fingerprint captured
when planning. If settings were changed during deployment, AWS completion is
reported but existing provider settings are preserved. The operator/user must
review the recorded outputs before any manual connection. No budget, mint or
recipient policy is modified by provisioning.

When a session expires, credentials are discarded or the node restarts:

1. Reconnect setup credentials for the same AWS account and region.
2. Select the existing operation in Setup history.
3. Use **Reconcile deployment**. If an unstarted/uncertain create is absent,
   retry the **same deployment**, not a fresh environment.

Runtime verification failure does not undo the stack. Fix the node identity,
trust or required permissions and choose **Verify runtime access**. This check
assumes the restricted role and reads the queue, exact definition/image and
staging prefix. It does not establish permission to run arbitrary jobs.

## Optional paid synthetic verification

Keep `aws_setup_probe_enabled` false until the approved worker image contains:

- Python 3 and boto3;
- this source's `priv/aws_setup/aws_smoke.py` at `/opt/ecai/aws_smoke.py`;
- an image entrypoint that permits Batch to run the configured command.

The verification job invokes `python3 /opt/ecai/aws_smoke.py`. Its environment
contains only the synthetic bucket/prefix, never setup keys. The worker gets
temporary task-role credentials through the AWS task credential mechanism.
It reads a tiny generated input object and writes a nonce and input SHA-256;
the coordinator independently validates those output values.

This is **one separately approved diagnostic per setup operation**, not a real
index rebuild. It requests 1 vCPU/2 GiB, one attempt and a 300-second running
timeout. Queue time is separate. Its AWS charges are outside the existing
indexing reservation ledger and are not an invoice ceiling or a price quote.
No diagnostic runs during connection, planning, provisioning or verification.

`SUBMITTING` is durably written before `SubmitJob`. SDK submission retries are
disabled because SubmitJob has no client idempotency token. An uncertain result
becomes `UNKNOWN`; reconciliation searches the recorded unique job name, checks
queue/definition/tags, and never auto-submits another copy. If no job can be
confirmed, inspect AWS before resolving the operation. Do not blindly repeat a
new probe. Successful probe output is `VERIFIED`, not “indexing enabled.”

## Removal and retained charges

Removal requires fresh setup authorization, typing the exact stack name and
explicit acknowledgment that S3 artifacts remain. Active or uncertain synthetic
jobs must first settle/reconcile. The delete request is bound to the recorded,
owned stack and stable delete token. It does not empty customer storage.

The S3 bucket and its TLS-only policy are **retained on deletion or rollback**.
Compute, network, role and log resources are requested for deletion; failures
remain visible and may need AWS-console attention. Stored artifacts continue
to incur charges until the customer separately removes them. An imported
provider is removed locally only if it still matches the record; later manual
changes are never deleted by a stale operation.

## API

All paths begin `/ecai/compute/aws/setup` and return `{ok,data}` or a safe
`{ok:false,error}`. Reads use bearer-authenticated GET; writes use JSON POST.
The body limit is 16 KiB. Unknown keys are rejected. No endpoint accepts a raw
CloudFormation template, arbitrary image, executable or AWS endpoint URL.

| Suffix | Purpose |
| --- | --- |
| GET root | Node capability/blockers, account operation summaries, current bearer-bound session metadata |
| GET `/:id` | Owned operation details including immutable template |
| POST `/connect` | `{region,credentials:{access_key_id,secret_access_key,session_token}}` |
| POST `/disconnect` | `{session_id}`; discard setup credentials |
| POST `/plan` | `{session_id,options}` + `Idempotency-Key` header |
| POST `/:id/discard` | `{}`; discard only an unused local plan |
| POST `/:id/deploy` | `{session_id,plan_sha256,confirm:"create aws environment",acknowledge_costs_and_iam:true,replace_connection:false}` |
| POST `/:id/reconcile` | `{session_id}`; observe the same owned stack |
| POST `/:id/verify` | `{}`; restricted runtime-role read checks |
| POST `/:id/probe` | `{confirm:"run paid verification job"}`; separate chargeable consent |
| POST `/:id/probe-status` | `{}`; reconcile the recorded diagnostic |
| POST `/:id/delete` | `{session_id,confirm:"<exact stack name>",retain_artifacts:true}` |

## Tests and deployment checks

```sh
node --check apps/ecai/priv/static/js/ecai-aws-setup.js
python3 -m unittest \
  apps/ecai/test/test_aws_setup.py \
  apps/ecai/test/test_compute_dashboard_contract.py \
  apps/ecai/test/test_compute_only.py
python3 apps/ecai/test/test_aws_setup_browser.py --dom-only
python3 apps/ecai/test/test_compute_provider_browser.py --dom-only
rebar3 compile
rebar3 eunit --module=ecai_aws_setup_tests,ecai_compute_settings_tests
```

The Python suite needs the pinned boto3 dependency; browser tests additionally
need Playwright and Chromium (`ECAI_CHROMIUM` may select the executable).
The regular browser mode serves mock routes; `--dom-only` is an offline adapter
for environments that prohibit browser HTTP navigation. It substitutes a test
HTTPS location (and UUID shim) solely in the fixture, not production code.
It does not validate actual TLS, Origin/proxy headers or HTTP caching.

Local validation: **40 Python/Node-backed contract tests and 18 browser test
cases passed** (nine new wizard tests plus nine preserved manual/compute tests),
including real botocore request-shape validation with Stubber. Layouts cover
light/dark 1200/945/390/320 viewports for the new wizard. All cloud responses are
mocked; no real credentials, AWS resources or customer data are used. Native
EUnit tests for TLS peer policy, ownership, redaction, recovery fences and
provider compare-and-swap are included but were not executed.

**Erlang compilation/EUnit, a complete Cowboy/DamageBDD authentication run,
CloudFormation service-side template validation and live AWS deployment were
not performed in this environment.** Erlang/rebar3 are absent; installing them
was blocked by package-network DNS. Passing offline SDK/browser tests is not
an AWS deployment certificate. Roll out to one allowlisted non-production AWS
account first, review IAM/resource plans, compile/run the native suite, and
verify deletion/retention behaviour before enabling more accounts.

Primary API references used in implementation:

- CloudFormation CreateStack: https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_CreateStack.html
- STS GetCallerIdentity: https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html
- Fargate compute environment constraints: https://docs.aws.amazon.com/batch/latest/userguide/fargate-compute-environments.html
- CloudFormation Batch container properties: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-batch-jobdefinition-containerproperties.html
- CloudFormation S3 bucket retention: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-s3-bucket.html
