# ECAI Ollama HTTP API

ECAI exposes an Ollama-compatible inference gateway on the normal ECAI Cowboy listener (default `127.0.0.1:9003`). The gateway uses `ecai_ollama_pool`; it does not maintain a second backend list.

## Endpoints

- `GET /api/tags`
- `POST /api/show`
- `POST /api/chat`
- `POST /api/generate`
- `GET /api/version`
- `GET /api/ps`

`/api/chat` and `/api/generate` preserve native Ollama request fields for Ollama backends. The pool forces the upstream request to `stream=false` so capacity, retries, and billing-sensitive receipts cover the complete provider call. If the client requested streaming (or omitted `stream`, whose Ollama default is true), the gateway returns one final NDJSON event. This is client-compatible buffered streaming, not token-by-token proxy streaming.

## Authentication

`ollama_api_auth_required` defaults to `true`. The gateway accepts either the normal DamageBDD managed-account bearer credential or an account-scoped ECAI Ollama API key. Backend provider credentials are taken from the managed node configuration; incoming client credentials are never forwarded to the provider.

Ollama API keys are managed from **Dashboard → Keys** (`/dashboard#keys`). The full secret is returned only on create/rotate; ECAI persists only a SHA-256 digest of the 256-bit random secret plus the key id, label, scopes, timestamps and owner. Revocation is checked on every new Ollama request.

Key-management routes require a managed DamageBDD account and do not accept Ollama API keys as management authority:

- `GET /ecai/keys/ollama` — list keys and status; never returns secrets.
- `POST /ecai/keys/ollama` — create a key and reveal its secret once.
- `POST /ecai/keys/ollama/:id/rotate` — revoke the old key and reveal a replacement once.
- `POST /ecai/keys/ollama/:id/revoke` — revoke a key immediately.
- `GET /ecai/keys/ollama/quick-config` — return endpoint and client templates containing a placeholder.
- `POST /ecai/keys/ollama/quick-config` — create a key and return ready-to-copy configuration with the new secret once.

Scopes are `models`, `chat`, and `generate`; the gateway maps them respectively to discovery/show/process/version calls, `/api/chat`, and `/api/generate`.

For a deliberately unauthenticated loopback-only development instance:

```erlang
{ollama_api_auth_required, false}
```

Do not disable authentication on a listener reachable by untrusted hosts.

## Managed model roles

The inference pool now supports the `chat` role. Nodes that should serve the Ollama gateway must include it when `roles` is specified explicitly:

```erlang
#{
  id => workstation_0,
  provider => ollama,
  host => "192.168.1.20",
  port => 11434,
  roles => [learning, synthesis, audit, patch, chat],
  models => ["qwen3-coder:30b"],
  max_inflight => 2
}
```

Nodes that omit `roles` receive the full default role set, including `chat`.

## Public model tags

`/api/tags` is generated from healthy/degraded `chat`-capable pool nodes. Native Ollama models keep their normal name. OpenAI-managed models are namespaced as `openai/<model>`.

For each managed model the registry also exposes:

- `ecai/<model>-rag-v1` — public ECAI index context, with graceful no-context fallback.
- `ecai/<model>-code-v1` — code index context when `ollama_api_code_index_dir` is configured; otherwise the code-learning architecture card.
- `ecai/<model>-strict-v1` — requires public index evidence and returns HTTP 422 when none is available.
- `ecai/chat:latest` — alias to the preferred model with the RAG profile.
- `ecai/code:latest` — alias to the preferred model with the code profile.

The backend model name is never accepted directly from an ECAI tag suffix. The public tag is resolved server-side to a provider/model pair from the managed pool and is restored in the Ollama response.

## ECAI retrieval configuration

```erlang
{ollama_api_rag_top_k, 8},
{ollama_api_context_max_bytes, 32768},
{ollama_api_rag_index_dir, "/var/lib/damage/ecai/wikimedia/enwiki"},
{ollama_api_code_index_dir, "/var/lib/damage/ecai/code-index"}
```

The wrapper uses `ecai_ollama_rag:retrieve_sources_lexical/3`, which deliberately performs no implicit embedding/model call. All generation remains under `ecai_ollama_pool` control.

## Client example

```python
from ollama import Client

client = Client(
    host="http://127.0.0.1:9003",
    headers={"Authorization": "Bearer <ecai-ollama-api-key>"},
)

response = client.chat(
    model="ecai/qwen3-coder:30b-code-v1",
    messages=[{"role": "user", "content": "Explain the repair queue."}],
    stream=False,
)
print(response.message.content)
```

For `stream=True`, the current implementation yields one final Ollama response event.

## Quick client configuration

The Dashboard Keys page exposes copy-ready environment, Python, JavaScript and curl examples. For deployments behind a reverse proxy, set `ollama_api_public_base_url` so the generated snippets use the externally reachable HTTPS origin rather than the listener address.

```erlang
{ollama_api_public_base_url, "https://ecai.example.com"},
{ollama_api_quick_model, <<"ecai/chat:latest">>},
{ollama_api_key_limit_per_account, 20}
```

A typical environment setup is:

```sh
export OLLAMA_HOST="https://ecai.example.com"
export OLLAMA_API_KEY="ecai_ollama_..."
```

For custom ECAI hosts, use clients that support custom headers. The Python and JavaScript examples generated by the quick-config route explicitly send `Authorization: Bearer $OLLAMA_API_KEY`.
