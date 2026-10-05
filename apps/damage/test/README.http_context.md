# Damage HTTP feature-context EUnit coverage

This test bundle verifies the `damage_http` feature-context seam without
starting Cowboy, Aeternity, IPFS, the balance cache, or the Gherkin runner.

## Production patch

The patch makes one behaviour-preserving refactor:

- `check_execute_bdd/4` delegates to `check_execute_bdd/5` with the existing
  production dependencies.
- `effective_context/2` delegates to `effective_context/3` with
  `damage_context:effective_context/2`.
- The extra arities are exported only when `TEST` is defined.

The production dependency map still calls exactly:

```erlang
damage_context:effective_context/2
execute_bdd/3
get_config/3
damage_ae:balance/1
```

## Covered cases

### HTTP/context boundary

- Authenticated state overrides request-supplied `public_key` and token.
- `address` is used when `public_key` is absent.
- Missing identity is passed explicitly as `undefined`.
- Wallet and agent scope selections are forwarded.
- Runtime fields such as concurrency, stream mode and run id are forwarded.
- Different accounts resolve independently.
- The context builder's frozen map is returned unchanged.

### Feature execution orchestration

- Context is built exactly once.
- Dry-run-only execution does not query balance or start a paid run.
- Dry-run failures stop before balance lookup.
- Insufficient balance stops before the paid run.
- Balance is checked for the authenticated account, not a spoofed request key.
- The paid run reuses the exact frozen context snapshot.
- Only the dry-run copy changes `stream` to `nostream`.
- Node, account, wallet and agent values and proofs survive both phases.
- Sensitive account values remain available to feature execution.
- The feature body comes from the HTTP request map for both phases.
- Address-only wallet execution uses the address for balance lookup.

## Run

```bash
rebar3 eunit --module=damage_http_context_tests
rebar3 eunit --module=damage_http_execution_context_tests
```

Or run the full Damage application EUnit suite:

```bash
rebar3 eunit --application=damage
```
