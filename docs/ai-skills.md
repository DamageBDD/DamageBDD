# DamageBDD AI skill steps

## What this adds

`steps_ai` turns explicitly supplied input into a named, typed AI result. A skill
is a versioned task contract, not an agent with permission to execute arbitrary
actions. Generated code, commands and tool calls are never executed.

The layers are:

```text
Gherkin -> steps_ai -> damage_ai -> damage_ai_backend:invoke/2
                                      |
                                      +-> damage_ai_openai
                                      +-> your trusted ECAI adapter
```

The supplied backend implements non-streaming Chat Completions and Embeddings
through an OpenAI-compatible HTTP API. It is not a Responses, Anthropic, Gemini,
vision, audio, browsing, tool-execution or agent-loop implementation. Parameter
support varies by server and model; select the settings for your deployment.

## Files and installation

Add the four production modules under `apps/damage/src`. Add the three test
modules under `apps/damage/test`. Merge the `ai_profiles` and `ai_skills` tuples
from `config/ai.config.sample` into the existing `damage` application entry.
The sample is NOT a replacement for your complete `sys.config`.

```sh
rebar3 compile
rebar3 eunit --module=steps_ai_tests
rebar3 eunit --module=damage_ai_openai_tests
```

This addition uses the existing `jsx`, `gun`, `damage_gun`, `crypto` and
`secrets:retrieve_decrypt/1` interfaces. It introduces no additional package
dependency or persistent supervised service. `secrets` is used only for a
configured `{api_key, {secret, Key}}` reference. The existing application must
have its normal Gun/TLS dependencies started.

The supplied runner discovers steps through `damage_utils:loaded_steps/0`.
After compiling/reloading, check in the running node:

```erlang
code:ensure_loaded(steps_ai).
lists:member("steps_ai", damage_utils:loaded_steps()).
```

The second expression must return `true`. An installation using a static step
registry must add `steps_ai` there. This patch does not guess at or replace an
unprovided `damage_utils`, application configuration, runner or supervisor.

The example feature files are live inference scenarios, not CI unit tests.
They require configured models and authorization; do not include them in an
unattended paid test run without an explicit decision. The cosine threshold is
illustrative: calibrate it against a labelled dataset and your selected model.

## Profiles and authorization

Configuration is exclusively trusted application environment, using tuples and
proplists. Feature files can choose only an existing binary-named profile. They
cannot choose an arbitrary backend module, URL, model, key reference or extra
HTTP headers. No configuration is read from untrusted per-run Config entries.

Every real invocation re-checks `allowed_accounts` against the authenticated
`Context.public_key`, and `allowed_skills` against the requested skill. Both
allowlists default to empty. The execution entry point is responsible for
establishing that account identity; this module is not an authentication layer.
Profiles share their configured provider credential among the explicitly
allowed accounts. Do not treat the existence of a profile as public permission
to spend its provider balance.

The `local` sample uses numeric loopback HTTP. Non-loopback endpoints must use
HTTPS with peer/hostname verification via `damage_gun`. HTTP is allowed only
for literal `127.0.0.1` or `::1` when `allow_loopback_http` is explicitly true.
Userinfo, query strings and fragments in endpoint URLs are rejected. Redirects
are not followed. Existing `damage_gun` proxy policy remains in effect.

For the OpenAI profile, `max_completion_tokens` is the default token field.
For compatible servers requiring it, set `{token_limit_key, max_tokens}`.
`temperature` is omitted unless the operator supplies it, avoiding an unwanted
assumption that every model supports that parameter.

`json_mode` is one of `prompt_only`, `json_object`, or `json_schema`. In all
modes, classification and extraction outputs are validated locally. Strict
schema requests are generated for these two built-ins when `json_schema` is
selected. Custom `json_object` skills have no arbitrary schema validator and
use JSON-object mode when strict schema mode is selected.

## Built-in skills

| Skill | Additional input | Returned value |
|---|---|---|
| `summarize` | Optional instruction | Text summary |
| `classify` | JSON array of allowed labels | One validated label as text |
| `extract` | JSON object mapping field names to primitive types | Validated JSON object |
| `rewrite` | Instruction | Rewritten text |
| `translate` | Target language | Translated text |
| `answer` | Question | Answer prompted to use only the supplied evidence |
| `prompt` | Optional instruction; task may be in input | Text |
| `embed` | Configured embedding model | Numeric vector |

Extraction accepts only `string`, `number`, `integer`, and `boolean` field
types. Every declared key must be present; absent facts must be represented by
`null`; additional keys and wrong non-null types are rejected. This is a small,
flat field contract, NOT a complete JSON Schema implementation. Arrays, nested
schemas, references, regular-expression constraints and schema composition are
not implemented.

Built-in prompt versions are `1`. Changing their semantics should increment
the version. Configured skills must supply `version`, `instruction`, and an
`output` of `text` or `json_object`; they must also appear in the profile's
allowlist. They cannot override built-ins. Custom JSON-object output is checked
for JSON/object structure only; use explicit assertions for required fields.

## Step catalogue

Quote every variable argument to match DamageBDD's quoted-token convention.
The body in the examples below means a Gherkin triple-quoted docstring.

```gherkin
Given I use AI profile "local"
Given I set the AI input to
  """
  Explicit source text.
  """
Given I use variable "ticket" as AI input
Given I use the HTTP response body as AI input
Given I set the AI instruction to
  """
  Preserve identifiers and uncertainty. Use three short sentences.
  """
Given I set the AI labels to
  """
  ["billing", "technical", "sales"]
  """
Given I set the AI fields to
  """
  {"order_id":"string", "amount":"number"}
  """
Given I set the AI language to "French"
Given I set the AI question to "What restored service?"
When I run AI skill "summarize" and store result in "ai_summary"
```

Natural-language aliases also exist:

```gherkin
When I summarize the AI input and store result in "ai_summary"
When I classify the AI input and store result in "ai_category"
When I extract fields from the AI input and store result in "ai_order"
When I translate the AI input and store result in "ai_translation"
When I embed the AI input and store result in "ai_vector"
```

Deterministic local assertions:

```gherkin
Then the AI result should equal "billing"
Then the AI result should contain "INC-481"
Then the AI result should be valid JSON
Then the AI result at pointer "/order_id" should equal JSON
  """
  "A123"
  """
Then the AI request should finish within "5000" milliseconds
Then the AI token usage should not exceed "2048"
Then the AI embedding should have "768" dimensions
Then AI embeddings in "ai_a" and "ai_b" should have cosine similarity at least "0.80"
```

These catalogue entries are independent examples, not one combined scenario.
Token assertions fail when the provider does not supply total usage. JSON
comparison is exact Erlang equality after decoding: `42` and `42.0` differ.
Pointer assertions implement slash-separated JSON Pointer with `~0` and `~1`
escapes and zero-based array indices; this is not JSONPath.

Cosine assertions require named embedding results from the same profile and
reported model, equal nonzero dimensions, and nonzero vector norms. The cosine
score is a geometric measure, not a probability of semantic correctness.

## Composition and result metadata

Destination names must match `ai_[A-Za-z0-9_]{1,64}`. Values are stored using
string keys, matching the supplied `steps_http` variable-setting convention:

```erlang
Value = maps:get("ai_summary", Context).
Metadata = steps_ai:result(Context, "ai_summary").
```

Text, JSON objects and embedding vectors retain their types. Chain skills
without serializing/templating the complete execution context:

```gherkin
When I summarize the AI input and store result in "ai_summary"
Given I use variable "ai_summary" as AI input
And I set the AI language to "French"
When I run AI skill "translate" and store result in "ai_french_summary"
```

A result contains `kind`, `value`, `profile`, `model`, `skill`, `skill_version`,
`elapsed_ms`, `usage`, `task_sha256`, and `output_sha256`. Usage contains only
provider-supplied nonnegative input/output/total token counts. The task digest
covers the serialized normalized task, not the complete HTTP payload, model
weights, sampling configuration or authenticated execution transcript. Hashes
are not signatures, proof of correctness, or a privacy mechanism.

Selecting a profile clears current task input, parameters and last result,
but preserves named results and per-profile call counters. Set the profile in
each Background to avoid reusing input between scenarios in runners that carry
context across scenarios. Counters persist for as long as that context persists.
Setting new input or task parameters invalidates the current last result.

## Execution and safety boundaries

Dry runs only recognize supported step patterns and reserve textual destination
placeholders. They do not contact a model, read secrets, check live profiles,
evaluate assertions or claim real inference results. A direct `step/6` call
with `{dry_run, true}` has the same protection. Unknown steps still raise a
`step/6` function-clause mismatch so other step modules remain discoverable.

Real calls have a whole-call deadline, bounded input and serialized request,
a receive-side HTTP body limit, and a per-profile call count. Failures consume
an attempted call slot once invocation is admitted. HTTP POSTs are not retried;
a timeout may still have consumed provider tokens. The built-in adapter rejects
refusals, truncated completions and tool-call results rather than treating them
as successful text. It does not expose raw provider error bodies.

The per-context `max_calls` counter and output token limit are NOT a global
account quota, monetary reservation, distributed rate limit or billing meter.
A new execution has a new counter. The existing runner's step charging is not
changed, and provider inference charges are not automatically reconciled into
DAMAGE accounting. Public multi-tenant deployment still needs server-side
account budgets, concurrency control and admission policies around execution.

Only explicit input and task parameters are sent to a backend, not the complete
context, cookies or HTTP authorization headers. A convenience variable lookup
blocks several known credential/context keys, but it is not a general data-loss
prevention classifier. A user can intentionally place sensitive text in input.

The new modules do not log prompt bodies or API keys. However, source features,
input, outputs and result metadata live in the execution context and may enter
your existing report/log/IPFS pipeline. This module does not make that pipeline
private. Use synthetic/redacted data for public verification jobs. Custom
adapters must apply the same secret/error handling discipline.

Model output remains untrusted data. The instruction to ignore commands in the
input is not a security boundary or a guarantee against prompt injection.
Likewise, summarization fidelity and evidence-grounded answers are requested
behaviours, not facts established by parsing JSON. Keep independently specified
assertions and labelled evaluation datasets; never let a model approve its own
generated tests or authorize privileged actions.

## Native ECAI integration

Implement `-behaviour(damage_ai_backend)` in a trusted local adapter and set its
module atom as the profile's `backend`. The callback receives `(Profile, Request)`
and must return one of:

```erlang
{ok, #{text => <<"...">>, model => <<"pinned-engine-id">>, usage => #{}}}.
{ok, #{embedding => [0.1, 0.2], model => <<"pinned-embedding-id">>, usage => #{}}}.
{error, backend_failed}.
```

A chat request has atom keys `operation`, `messages`, `json`, and `schema`;
message content uses binary JSON keys. An embedding request has `operation`
and `input`. Respect the profile's limits, do not log secrets, and do not spawn
unmanaged work that survives cancellation. Reject partial/refused completions
inside the adapter. The common layer handles deadlines, output validation and
metadata. No unverified existing ECAI function signature is assumed here.

## Validation status

The supplied EUnit suites cover task contracts, authorization, dispatch,
tokenization, dry-run behaviour, timeouts/cancellation, redaction, named result
handling, JSON Pointer, cosine checks, HTTP payload/decode behaviour and four
loopback HTTP transport cases. They require Erlang/rebar3 and the project's
existing dependencies. No live provider credentials are needed for these tests.

This delivery environment has no Erlang or rebar3 executable, so compilation,
EUnit execution and full runner integration were NOT performed here. Source
structure and patch application were checked separately; those checks do not
substitute for compilation. Run the commands above before merging.

## Protocol references

Official API contracts consulted while writing the adapter:

- OpenAI Chat Completions: `https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create`
- Ollama compatibility: `https://docs.ollama.com/api/openai-compatibility`
- Gun await API: `https://ninenines.eu/docs/en/gun/2.4/manual/gun.await/`
