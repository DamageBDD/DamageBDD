# Execution runtime + account context editor

This patch adds an execution-context editor beside the feature picker.

## Runtime context

Runtime context is per-browser-session and per-execution. The dashboard sends it
inside JSON execution requests:

```json
{
  "feature": "Feature: ...",
  "concurrency": 1,
  "stream": true,
  "context": {
    "server": "https://api.example.com",
    "region": "au"
  }
}
```

The server merges `context` into the runtime execution map before
`damage_context:prepare_run_context/1`. Explicit execution control fields in the
outer JSON object win over nested context.

## HTTP/text requests

Plain-text execution requests can set runtime context with one JSON header:

```http
X-Damage-Context: {"server":"https://api.example.com","retries":3}
```

or individual context headers:

```http
X-Damage-Context-server: https://api.example.com
X-Damage-Context-retries: 3
X-Damage-Context-enabled: true
```

Individual values are decoded as JSON scalars when possible. Otherwise they
remain strings. Individual headers override keys from `X-Damage-Context`.

Example:

```bash
curl -X POST https://run.dev.damagebdd.com/execute_feature/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" \
  -H 'X-Damage-Context: {"region":"au","retries":2}' \
  -H 'X-Damage-Context-server: https://api.example.com' \
  --data-binary @feature.feature
```

## Account context

The editor loads `GET /context` and performs versioned `PATCH /context`
mutations. Sensitive values stay redacted; an edit requires a replacement
value. Account context is persistent and participates in the normal scoped
context merge before per-run runtime context.

## Precedence

The existing scoped-context precedence remains unchanged:

```
node defaults
< account context
< wallet/agent context
< runtime context
< locked node values
< protected runtime identity
```

Nested/header context cannot replace request control fields (`feature`,
`stream`, `concurrency`, etc.) and authenticated state still wins for protected
identity fields.
