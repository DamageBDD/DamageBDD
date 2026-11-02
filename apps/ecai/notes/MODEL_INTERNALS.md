# Model Internals

Location: **ECAI Dashboard → Code Learning & Repair → Model Internals**.
Deep link: `/dashboard#code/model-internals`.

This is a node-admin control plane for the existing code-inference pipeline.
It is not a tensor debugger, a new inference server, or a claim that language
model output becomes deterministic or correct when a policy is enabled.

## Deployment

From the DamageBDD umbrella checkout that contains the supplied ECAI source:

```sh
git apply --check "$HOME/Downloads/ecai-model-internals.patch" &&
  git apply "$HOME/Downloads/ecai-model-internals.patch"
rebar3 compile
rebar3 eunit --module=ecai_model_internals_tests
```

Restart the node using its usual service/launcher after the initial deployment.
The restart installs the new child before the inference pool and loads the new
routes. Merely reloading the static page does not start an added OTP child.
Subsequent policy changes take effect without restarting the node.

The existing settings remain authoritative:

```erlang
{ecai, [
    {code_security_enabled, true},
    {code_admin_enabled, true}
]}.
```

Merge those keys into existing configuration; do not replace the application's
other settings. Configure the authenticated account in DamageBDD's existing
`node_admins` policy. A nonempty `ecai.code_admin_accounts` remains an additional
restriction. Wallet-only sessions do not gain node-admin permissions.

The new policy defaults to **disabled**. Every numeric override defaults to
`null`, meaning inherit the existing node/request value. Opening this page,
refreshing telemetry, or previewing a draft does not initiate inference.

## Working controls

| Surface | Implementation |
| --- | --- |
| Role scope | `patch`, `learning`, `audit`, `synthesis`; repair is selected initially. |
| Ollama sampling | Temperature, top-p, top-k, min-p, seed, repetition penalty. |
| Ollama resource controls | Context tokens and maximum output tokens (`num_predict`). |
| OpenAI adapter | Existing Responses adapter: maximum output tokens and optional temperature. Leave temperature unset when the selected model rejects it. |
| System guidance | Append a maximum of 2,048 UTF-8 bytes to existing system guidance; do not replace it or execute it. |
| Patch structure | Opt-in fixed Ollama JSON schema for repair JSON requests. Other JSON requests keep their current format. |
| Preview | Pure validation and compilation of draft overrides for a provider/role. No inference or remote discovery. |
| Policy history | Revision, actor, timestamp and configuration fingerprint; latest 32 changes retained. |
| Observations | Latest 32 successful code calls, including policy metadata when applied. Metadata only; volatile. |

The capability map describes **ECAI wiring**, not negotiated support for every
model or remote runtime version. Existing pool health is displayed separately.
Unsupported provider parameters can still be rejected by that provider; the
integration does not silently retry with a less restrictive policy.

Custom logits processors, activation/attention hooks, LoRA/weight loaders,
KV-cache inspection and soft-prompt injection are displayed as **Runtime
required**. This patch neither installs those runtimes nor provides switches
that pretend to enable their capabilities. It accepts no executable code,
adapter paths, arbitrary endpoints or credentials.

Public/native chat and generation, the `chat` role, and evaluation calls are
outside this policy. Existing tools, evidence collection, patch validation,
compilation, tests, reviewer authorization and publication gates are unchanged.
Constrained JSON validates shape, not semantics or patch safety. A fixed seed
or zero temperature does not guarantee identical output across runtimes,
hardware, model versions or serving conditions.

## Runtime flow

1. `ecai_ollama_pool:run_request/4` captures the enabled policy once, before
   checkout. Only JSON/text requests for selected code roles are eligible.
2. The existing pool selects the provider, model and destination. The policy
   overrides only its allowlisted controls after that selection.
3. Provider serialization sends the supported fields. Ollama JSON generation
   uses the fixed schema only for opted-in repair requests.
4. The policy revision, hash and applied-control names accompany successful
   results. `ecai_patch_worker` retains this metadata in its existing durable
   repair-attempt history.
5. Billing-sensitive receipt identity incorporates effective output settings,
   including node defaults, system guidance, schema and policy metadata. An
   output produced under different settings is not reused as the same receipt.

A single pool call's failover/transport retries retain the captured policy.
A new logical call, including a repair resumed after a process/node restart,
captures the then-current policy. This feature does not add hidden-state or
KV-cache checkpoint restoration.

Policy metadata identifies what the ECAI bridge requested; it is not remote
attestation that a model applied every parameter.

## Persistence and authorization

`ecai_model_internals` is a supervised worker immediately before the inference
pool in the code-security `rest_for_one` tree. Saved state is located at:

```text
<ecai_paths:state_dir()>/code_model_internals.term
```

Writes use a unique, exclusively created temporary file with mode `0600`, a
file sync, close, then rename. A failed write does not replace the active
snapshot. This does not claim a portable parent-directory fsync/power-loss
transaction guarantee. Back up the file through normal node-state backups.

Saved state is decoded with `binary_to_term(..., [safe])` and schema/hash
validation. Corrupt/unreadable saved state fails service startup rather than
silently replacing an enabled policy with defaults. Restore a known-good
backup before restarting; moving the file aside deliberately resets the
policy to disabled and discards that saved history.

A configuration fingerprint is the lowercase SHA-256 of
`term_to_binary(Config, [deterministic])`; the system-guidance fingerprint uses
the same encoding rule. These are local Erlang term fingerprints, not JSON
canonicalization, digital signatures, authenticity proofs, truth proofs or
post-quantum attestations.

Existing node-admin authentication applies to all three routes. Both POST
routes require the exact explicit bearer token to resolve to the authorized
principal; a cookie plus an unrelated bearer is insufficient. JSON bodies are
bounded at 8,192 bytes, unknown configuration fields are rejected, and no
client-provided actor/account identity is accepted.

Full configuration replacements require the revision that was edited. Saves
are serialized and stale revisions return HTTP 409. The browser preserves the
draft on conflict. Refresh telemetry, then explicitly discard local edits to
load the latest revision before making a new edit.

## API

```text
GET  /ecai/admin/code/model-internals
POST /ecai/admin/code/model-internals/update
POST /ecai/admin/code/model-internals/preview
```

The GET response returns `{ok: true, model_internals: ...}` with configuration,
revision, capabilities, policy history, sanitized existing-pool status and
recent observations. Endpoint/credential configuration is not returned.

Update body (supply the complete config from GET or the dashboard form):

```json
{"revision": 0, "config": {"...": "complete config, not a partial patch"}}
```

Preview body:

```json
{"provider": "ollama", "role": "patch", "config": {"...": "complete draft config"}}
```

Examples above show the envelopes, not valid substitute configurations.
A preview uses revision 0 as a draft marker, returns only overrides rather
than inherited node settings, and neither saves nor calls a model.

## Tests

```sh
python3 -m unittest discover -s apps/ecai/test -p 'test_model_internals_contract.py'
python3 -m unittest discover -s apps/ecai/test -p 'test_console_contract.py'
python3 apps/ecai/test/test_model_internals_browser.py
rebar3 eunit --module=ecai_model_internals_tests
```

The Chromium test requires Playwright and Chromium. `CHROMIUM_PATH` selects the
binary and `ECAI_SCREENSHOT_DIR` sets its screenshot output directory. It runs
production component/markup and the real shell navigation functions, with
simulated transport and identity. It is not a live Cowboy/auth/provider test.

The new EUnit suite covers validation, provider isolation, policy pinning,
restart persistence, optimistic concurrency, file permissions, metadata
sanitization, option serialization, receipt identity and repair metadata.

The existing console contract has been extended by three endpoints. Three
stale assertions in the supplied test file have also been aligned with the
supplied production code: dynamic theme CSS, configurable review remotes and
the conversation-history route chain. No corresponding runtime behavior was
changed to make those assertions pass.
