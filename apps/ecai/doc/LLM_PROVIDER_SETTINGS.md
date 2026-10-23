# ECAI AI providers & roles

## What this change adds

Open **Dashboard → Settings → AI providers & roles** (`#ai-providers`).
The same page is linked from Node settings and Code Learning & Repair →
Model Internals. This is a node-administrator control plane, not a per-account
provider-preferences page.

It imports the existing `code_model_nodes` configuration, falling back to
`code_ollama_nodes` and then the existing local Ollama defaults. It reuses
`ecai_ollama_pool` and `ecai_ollama_client`; it does not introduce a second
Ollama/OpenAI transport or replace DamageBDD's existing standalone backends.
The client adds native Anthropic Messages support for Claude.

Each connection has an ID, provider, endpoint, enabled state, default model,
allowed models, role eligibility, scheduling weight, maximum concurrency,
connection/request timeouts, optional temperature and output-token default,
and a credential reference. The backend section exposes health interval,
health timeout, unhealthy threshold, queue deadline and routing attempts.
Role eligibility is `learning`, `audit`, `patch`, `synthesis`, `chat`, or `bdd`.

**Scheduling is the existing health/capacity/weight policy, not an ordered
primary/fallback list.** Every eligible connection uses its default model when
no explicit model is requested. To use different models for different roles,
create separate connection IDs, even when they share an endpoint.

## Deployment

Rebuild both apps in the complete DamageBDD umbrella and restart through the
normal release/service procedure. A compile-only hotload does not install the
new supervised registry child or new routes. The archive supplied for this
patch has application sources, not the full umbrella build/dependency tree.

```sh
rebar3 compile
rebar3 eunit --module=ecai_llm_settings_tests,ecai_anthropic_client_tests,ecai_llm_pool_reload_tests,damage_ai_ecai_tests
```

The existing `ecai.code_security_enabled` and `ecai.code_admin_enabled` gates
must be enabled. Authority remains `damage.node_admins`, optionally narrowed
by `ecai.code_admin_accounts`. A wallet-only session does not confer code-admin
authority. Mutations require the existing explicit bearer credential, resolved
and matched to the authenticated node administrator. Serve the dashboard over
HTTPS and preserve the deployment's existing browser-auth/origin restrictions.

See `apps/ecai/priv/examples/llm-settings.config.example` for **merge-only**
settings. Never replace an entire production `sys.config` with this fragment.
No existing AI profiles or allowed-account lists are modified automatically.

## Connect and assign

1. Sign in as an authorized node administrator and open the page. Revision 0
   displays inherited deployment configuration; opening the page does not save
   overrides or generate text.
2. Add a connection. New connections start disabled with no guessed model ID.
   Use the official provider endpoint, or an explicitly approved Ollama endpoint.
   Choose a server environment reference or enter a replacement API key.
3. Save the disabled connection, then use **Test & list models**. This tests the
   saved endpoint and credential/model-list access only. It does not verify that
   a particular model can generate, and sends no repository/private text.
4. Choose a discovered model or type an exact permitted model ID, assign roles,
   explicitly enable non-loopback processing for the required roles, then enable
   the connection and save. A generation capability check is not performed by
   model discovery; validate an actual workload separately.

The shared Chat toggle defaults off, retaining existing `ecai_chat` pool-level
Ollama configuration. Turning it on routes dashboard conversation synthesis
through the `chat` role. No eligible connection means a controlled error, not a
silent fallback to the old endpoint. This switch does not reconfigure private
corpus retrieval or third-party applications calling the client directly.

When dashboard overrides exist, internal learning, synthesis, audit, patch,
health-monitor and log-learning calls discard their old provider/model defaults
and use role routing. Learning-cache identity also recognizes Anthropic.
Explicit native API model selections, evaluation targets and private-corpus
LLM destinations are not rewritten. Workload-specific timeout/output limits
can still override shared connection defaults. Model Internals is a separate
policy; its existing provider-specific tuning remains Ollama/OpenAI-only.
Claude uses its connection options and each workload's existing instructions.

## Credentials and endpoint permissions

New API keys are written to the existing DamageBDD node-scoped encrypted secret
vault, using fresh `ecai-llm/<connection-id>/<random-id>` references and an explicit
DETS sync. The settings JSON and API responses contain references, never the key.
The vault must already be provisioned and available. The registry never creates
or replaces a wallet identity or changes vault-unlocking material.

The browser retains replacement keys only in the current in-memory draft. It
clears them after each save attempt, navigation away and identity reset. It does
not write them to local/session storage or send them directly to providers.
Browser extensions, developer tools, the application host and a compromised
administrator are outside this protection boundary; JavaScript strings are not
securely zeroizable. Avoid request-body logging at reverse proxies.

Blank replacement-key input preserves the selected credential reference.
Changing an inherited credential's destination requires selecting a new credential
source. A saved vault reference cannot be moved to a different endpoint on a
subsequent update without replacing the credential. Rotation never overwrites
a reference that an already issued lease may still use. Old encrypted entries
are intentionally not deleted automatically. A failed save after staging keys
can leave unused encrypted entries; reconcile them in the vault only after
checking saved configuration and outstanding requests. Back up both the registry
file and the existing vault/unlocking material.

New OpenAI/Anthropic connections are constrained to their official HTTPS hosts
and port 443. Already deployed compatible endpoints remain usable when their
provider/host/port/transport exactly match the server configuration. New arbitrary
compatible URLs/API modes cannot be created from this dashboard. Endpoint-specific
advanced settings (including a deployed base path or TLS configuration) are
preserved only for an unchanged deployment destination. Newly created HTTPS
connections use the existing client's certificate-verifying defaults. Managed
connections use direct networking and disable OpenAI response storage; this is
not a blanket guarantee about provider retention.

Ollama loopback access defaults to port 11434. Extra LAN/remote destinations must
already exist in deployment nodes or the operator-only
`ecai.llm_settings_ollama_endpoints` list. Hosted Ollama uses `ollama.com:443` with
TLS. The three built-in approved environment references are `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY` and `OLLAMA_API_KEY`; deployment references and explicitly
approved `llm_settings_allowed_envs` entries are also allowed. Arbitrary environment
variable names, raw headers, proxy settings, TLS overrides and callback modules
are not accepted from dashboard JSON.

**Remote providers receive workload plaintext.** Every role assigned to an enabled
non-loopback connection needs explicit non-loopback permission. This covers LAN
hosts too. Loopback is only the immediate network hop: local Ollama can itself
proxy cloud models. Audit/disable that separately for local-only workloads. The
settings do not override private-corpus destination allowlists or remote opt-in,
and they do not grant a model tool, execution, patch-approval or signing authority.

## Persistence and live application

The registry writes `<ecai_paths:state_dir()>/llm-settings/settings.json` with a
0700 settings directory and 0600 files. It validates a complete candidate, stages
new vault references, syncs an exclusive temporary file, renames it into place,
and publishes the new settings revision through the existing pool. A corrupt
saved file fails registry startup instead of silently re-enabling deployment
fallback. Back up state using the deployment's normal filesystem procedures;
this is not a distributed configuration/consensus service.

A save uses an expected revision. A concurrent stale edit returns 409 and preserves
non-secret browser edits. Refresh does not discard a dirty draft; Discard edits
loads the current saved revision. There is no applied-revision rollback history
UI in this version; restore a trusted registry backup while the service is
stopped when recovery is necessary.

Active leases retain their copied endpoint/model/options and credential references.
New configuration generations reject old health-probe and completion-health
results. In-flight counts are retained by connection ID; dead request owners
release capacity. Newly issued leases use the new registry. A queued request or
later retry may resolve against a newer revision: this is not whole-job snapshot
isolation. Environment-variable changes are external to credential references.
Explicitly saving an empty registry disables routing; it never reactivates the
legacy default connection. A saved revision and pool revision are displayed
separately so a pending/unavailable runtime is not falsely shown as applied.

Only this node's local shared registry is affected. State storage should not be
shared by independently writing BEAM nodes. No generic application-environment
editor is exposed, and worker-count/autoscaling settings are not changed here.

## DamageBDD profile bridge

`damage_ai_ecai` is an optional `damage_ai_backend` implementation for text/chat
skills. Opt a named profile into it in deployment configuration and assign at
least one enabled connection the `bdd` role. Existing `damage_ai_openai` profiles
and `damage_agent_llm_ollama` action-planning integrations are left unchanged.

The bridge preserves role messages, bounds request/response work using profile
limits, rejects incomplete OpenAI and truncated Ollama output, and returns the
existing `text/model/usage` contract. DamageBDD still enforces account/skill
allowlists, its overall deadline and local output validation. Missing usage is
omitted, not fabricated as zero. JSON classification/extraction is locally
validated by `damage_ai`; provider-native structured-output schema enforcement
is not added by this bridge. Embeddings are explicitly unsupported and should
remain on an existing embedding-capable backend/profile. Nothing in this page
turns generated text into permission to execute a BDD scenario or apply a patch.

## Claude adapter scope

The shared client uses `POST /v1/messages`, top-level system instructions,
`x-api-key`, `anthropic-version: 2023-06-01`, a required output cap and nonstreaming
responses. It supports text and JSON-text generation, not image input, tools,
extended thinking or realtime streaming. Truncation, refusal/unsupported stop
reasons and non-text blocks fail closed. Missing token usage stays unknown.
`GET /v1/models?limit=1000` supplies discovery; a paginated/incomplete result is
rejected rather than silently used as the authoritative model set. The
Ollama-compatible gateway can synthesize its usual envelope for text-only Claude
requests, but does not make unsupported native Ollama features available on Claude.

Evaluation can recognize explicitly permitted Anthropic targets, while retaining
its own target allowlist, configuration fingerprint and remote-processing policy.
Disabled registry targets are excluded from evaluation and virtual-model discovery.

Official API references:
- https://platform.claude.com/docs/en/api/messages
- https://platform.claude.com/docs/en/api/models/list
- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://docs.ollama.com/api/tags

## HTTP contract

All routes reuse `ecai_code_admin_http` authentication/authorization.

| Method | Route | Body / result |
| --- | --- | --- |
| GET | `/ecai/admin/llm/settings` | `{ok:true,llm_settings:{revision,source,config,pool,damage_profiles,...}}` |
| POST | `/ecai/admin/llm/settings/update` | `{revision,config}`; complete bounded config, optional write-only `api_key` per connection |
| POST | `/ecai/admin/llm/probe` | `{revision,id}`; saved target only, model IDs/elapsed time, `generation_tested:false` |

Unknown fields/roles/providers are rejected without interning atoms. Settings
mutation/probe bodies are limited to 128 KiB; other admin routes keep their
existing 8 KiB bound. There are at most 32 connections. Probes have bounded
response size and deadlines and a per-ID request-start throttle. Errors from
these routes omit provider payloads and key values. GET returns no credential
values and uses the existing no-store response headers.

## Verification

The bundle's `VALIDATION.md` records what actually ran. The isolated Chromium
suite exercises the real provider component against a simulated API, not live
Cowboy authentication or real provider accounts. EUnit suites are provided for
registry validation/persistence, Claude payloads/response handling, pool reload
and lease ownership, and DamageBDD result normalization. Run them in the complete
umbrella with Erlang/rebar3 before deployment. No production/provider credentials,
paid generation requests or live vault writes were used to build this patch.
