# ECAI OpenAI backend update

This patch is intended to be applied after `ecai_ollama_cluster.patch`.

It keeps `ecai_ollama_pool` and `ecai_ollama_client` names for backwards
compatibility, but makes both provider-aware. Workers may now be native Ollama
or OpenAI Responses API endpoints.

## OpenAI protocol

OpenAI workers use:

- `GET /v1/models` for authenticated health/model discovery.
- `POST /v1/responses` for inference.
- `Authorization: Bearer ...` authentication.
- `text.format.type = json_object` when ECAI requests JSON.
- `store = false` by default for code/security inference.

The response adapter extracts text from Responses API output items and returns
it through the same `{ok, Value, InferenceMeta}` contract used by Ollama.

## Authentication

Preferred pool configurations are references to secrets, never secret values:

```erlang
api_key_env => "OPENAI_API_KEY"
```

or:

```erlang
api_key_file => "/var/lib/damage/keys/openai_api_key"
```

Equivalent forms:

```erlang
auth => #{type => bearer_env, env => "OPENAI_API_KEY"}
auth => #{type => bearer_file, path => "/run/secrets/openai_token"}
```

`bearer_file` is re-read on each request, so an external credential agent can
rotate a short-lived bearer token without placing it in the learning snapshot.
Direct bearer values are rejected in `code_model_nodes` to avoid secret values
living in gen_server state or appearing in crash/status output.

Optional OpenAI account routing headers:

```erlang
organization_env => "OPENAI_ORG_ID",
project_env => "OPENAI_PROJECT_ID"
```

Direct `organization` / `project` IDs are also supported.

## Mixed providers

Each worker has its own `provider` and `default_model`. This removes the old
assumption that every pool member has the same model name. Roles provide the
routing boundary:

- `learning`
- `synthesis`
- `audit`
- `patch`

This makes it possible to keep high-volume repository learning on LAN Ollama
while sending only global synthesis or validated repair generation to OpenAI.

## Compatibility

`code_model_nodes` is preferred. If absent, the pool still accepts the previous
`code_ollama_nodes`; if neither exists, it creates the original single local
Ollama worker from `code_ollama_host`, `code_ollama_port`, and
`code_ollama_model`.

The old `code_ollama_*` cluster timing options remain fallbacks behind the new
`code_model_*` names.

## Learning snapshots

Snapshot schema is bumped to 2. `inference.pool_identity` is included in the
snapshot hash and contains only sanitized provider/model identity information.
Runtime health appears under `inference_pool`. Bearer credentials are never
included.

For Ollama, model digest remains part of identity. OpenAI's models endpoint does
not expose an equivalent digest, so OpenAI provenance records the provider,
model ID, and model `created` value when available. Use a pinned OpenAI model ID
when reproducibility across snapshots is important.

## Apply

```bash
git apply --check ecai_openai_backend.patch
git apply ecai_openai_backend.patch
rebar3 format
rebar3 compile
rebar3 eunit
```
