# Authenticated release NFT transfers

This version targets the supplied AE implementation with shared account nonce
locks, pinned node sessions and gas estimation. It replaces the older transfer
fixes; it does not restore the former wallet-queue or flat-gas implementation.

## Request

```http
POST /api/releases/nfts/42/transfer
Authorization: Bearer <access-token>
Content-Type: application/json

{"to":"ak_recipient..."}
```

The caller comes only from authenticated state. The server uses the configured
`build_release_nft_contract` and `build_release_nft.aes` source. The request
cannot choose a caller, key, contract, source path or entrypoint. The transfer
arguments remain `(to, token_id, None)`; the contract is the authority for NFT
ownership/operator permission and token existence.

An explicit `Authorization: Bearer ...` header is required. Cookie-only,
query-token-only and Nostr-header requests cannot authorize this mutation. No
query parameters are accepted, even alongside a Bearer header. The shared
`damage_http:is_authorized/2` function is called only after this gate, with a
fresh `#{action => transfer}` state rather than caller-supplied route state.

Only `application/json` is accepted; JSON media-type parameters are allowed.
Compressed bodies are rejected. The reader accumulates partial reads under a
4096-byte cumulative limit and a single 5000-ms deadline. Both final `ok` chunks
and intermediate `more` chunks are counted. The most recent Cowboy request is
used for the response. Empty partial chunks do not grow the accumulator.
Token IDs must use canonical positive decimal notation, with at most 39 digits.
The decoded body must contain only a non-empty binary `to` value (at most 64
bytes); the NFT module then validates the recipient account identifier.

The public current/latest/versioned GET/HEAD endpoints are unchanged.

## Outcomes

| HTTP | `status` | Meaning |
|---|---|---|
| 200 | `confirmed` | A mined receipt has positive height and a successful return type. |
| 202 | `submitted` | The node acknowledged the local hash, but no terminal receipt was obtained in the observation window. |
| 202 | `submission_unknown` | Submission was attempted, but acknowledgement/execution remains unresolved. The locally calculated hash is returned. |
| 202 | `signature_required` | Wallet preparation only. The server has not broadcast the returned transaction. |
| 409 | `rejected` | Final preflight, or a mined receipt, rejected execution. Mined rejections include the transaction hash. |
| 503 | `outcome_unknown` | An exceptional loss of the surrounding operation's result prevents a definite outcome. Reconcile before retrying. |

For example, a pending custodial response is:

```json
{
  "ok": true,
  "status": "submitted",
  "token_id": 42,
  "from": "ak_authenticated_account...",
  "to": "ak_recipient...",
  "tx_hash": "th_local_hash..."
}
```

`ok: true` is not, by itself, evidence that ownership changed. Check `status`.
`confirmed` does not enforce an additional confirmation depth or reorg policy.
Raw receipts, exception terms, private keys and contract-return payloads are not
included in public transfer responses.

Other errors: malformed token/body/address -> 400; missing or invalid Bearer
credentials -> 401 with a Bearer challenge; unavailable custodial key -> 403;
body timeout -> 408; oversized body -> 413; unsupported media type/encoding ->
415; authentication, preparation or chain infrastructure failure -> 503.

## Custodial execution

The handler re-reads the account associated with the authenticated username.
Its returned address must match the authenticated caller, and the private key
must have the 64-byte format expected by the current signer. The new tracked
AE entrypoint additionally uses `validate_account_signing_key/2` before any
submission, and strips unrelated keypair fields.

```erlang
damage_ae:contract_call_tracked(KeyPair, Contract, Source, Function, Args).
```

This opt-in API shares `with_account_nonce_locks/2` with the current regular
contract-call, deployment and PayingFor paths. It acquires the session inside
the lock. Preparation, final preflight, signing, posting and receipt observation
run in the same process with that pinned session. The lock is held through the
observation window even when the legacy `ae_serialize_until_mined` flag is false.

It reuses `post_tx_detailed/1`, `signed_tx_hash/1` and `wait_tx/1`, including the
current hash compatibility fallback, `already_known` handling and read-only
observer failover. The signed-envelope hash is calculated before the POST and
retained across normal submission/confirmation error paths. Only that local
hash is observed; an unexpected acknowledgement hash is not substituted.

The tracked API deliberately does not use the automatic nonce-rebuild/retry
wrapper. There is one POST attempt per invocation. A post-only error that lacks
a terminal receipt remains conservatively `submission_unknown`. Existing generic
`contract_call/[4,5,6]` behavior and its configured retry policy are unchanged.

`damage_release_nft:transfer/3` and the operator wrappers return the tracked
outcome, rather than the old raw call-info map. The historical
`invalid_release_operator_keypair` error is retained.

## Wallet preparation

```erlang
damage_ae:contract_call_prepare_checked(#{public_key => Caller},
    Contract, Source, Function, Args).
```

The existing `contract_call_prepare_tx/5` builder estimates execution gas and
converges its size-aware fee as before. The tracked layer then reads an uncached
top header from the pinned node and simulates the exact final unsigned bytes.
It does not rewrite nonce, gas or fee after the final successful simulation.

Final preflight requires success regardless of the estimator's
`ae_contract_reject_dry_run_revert` policy. Disabled/unavailable dry-run does not
fall back to an on-chain call. No private key is fetched and no transaction is
broadcast by preparation. Estimation may simulate drafts; the final check is
always against the transaction returned to the wallet or passed to signing.

The existing `dry_run_accounts/1` funding policy is retained. With simulated
caller funding enabled, a successful preflight is not proof that the caller can
pay the real transaction fee/gas. These transfers are not sponsored PayingFor
transactions; the signing account needs native AE for a real submission.

A wallet receives `token_id`, `from`, `to`, `contract_id` and `tx`, with
`status: signature_required` and `signing: wallet`. It must check the intended
network, recipient, token and fees before signing. Modifying transaction fields
invalidates the relationship to the server's preflight. Preparation does not
reserve a nonce or token ownership.

## Configuration and operational limits

The rebase reuses current settings; it introduces no new timeout settings:

```erlang
{damage, [
    {ae_node_pool_request_timeout_ms, 30000},
    {ae_tx_post_timeout_ms, 30000},
    {ae_tx_poll_interval_ms, 2000},
    {ae_tx_wait_timeout_ms, 180000}
]}.
```

These are the defaults in the supplied AE module. The previous bundle's
`ae_transfer_preflight_timeout_ms` and `ae_transfer_confirm_timeout_ms` are not
read by this version. Total request duration may also include lock contention,
preparation and network calls; the polling timeout is not an end-to-end HTTP
request deadline. Check client and reverse-proxy timeouts accordingly.

Do not automatically repeat a POST after `submitted`, `submission_unknown`,
`outcome_unknown` or a lost HTTP response. Reconcile the transaction and ownership
first. This change does not provide durable idempotency, a persistent submission
journal, or exactly-once execution. After a timeout the existing account lock is
released; it is not a durable reservation for unresolved transactions.

Coordination applies only to code using the same nonce-lock namespace. External
wallets, disconnected nodes and legacy helpers using other locks are not covered.
In particular, the supplied `contract_call_payfor_user_safe/5` helper has its own
older submission path; this transfer-focused patch does not rewrite it.

## Tests

```bash
rebar3 eunit --module=damage_ae_transfer_tests,damage_release_nft_transfer_tests,damage_releases_http_transfer_tests
```

The regression tests cover the public request gate, bounded fragmented body
reads, key/account checks, final-byte preflight, shared lock coordination,
retained session context, response classification, hash retention and no-retry
semantics. They use fixtures and private callback seams exposed only under TEST;
no live transfer is performed by this test suite. Dependencies such as Cowboy,
JSX, the AE encoder and the hash backend must be available through the project.

# Remaining NFT transfer review fixes

This is an incremental follow-up to the reviewed NFT-transfer and packaged-version diff.
The runtime patch expects these Git source blobs, not the earlier unpatched uploads:

- `apps/damage/src/damage_ae.erl`: `f184bf97f999b3202b39c7f88418e5ae59cd9883`
- `apps/damage/src/damage_releases_http.erl`: `054bcf15aa75f3f52e3cba534366fa89bb89c60c`

`damage_release_nft.erl` and `damage_release.erl` remain unchanged from the reviewed
baseline. The publication/version-binding and build-feature changes are untouched.

## Shared nonce coordination for staged PayingFor calls

`contract_call_payfor_user_safe/5` now validates and normalizes both keypairs,
locks both caller and payer in the existing sorted/deduplicated `tx_nonce`
namespace, then pins its node session inside the lock scope. Preparation,
submission and receipt observation stay inside that scope. It reuses
`build_account_contract_tx`, `next_nonce`, `build_paying_for_tx` and
`post_tx_detailed` rather than the obsolete standalone nonce/gas/POST logic.

The staged API never invokes the normal path's automatic nonce retry. It prepares
one signed transaction, calculates its hash before submission, and attempts one
POST. Lost acknowledgements and receipt failures retain that locally calculated
hash. Keypairs, raw backend responses and exception terms are not included in the
new diagnostic reasons.

The tuple API is preserved:

```erlang
{not_submitted, Reason}
{confirmed, TxHash, Call}
{uncertain, TxHashOrUndefined, Reason}
```

`confirmed` means a mined terminal receipt was observed, including a mined
contract revert or VM error. Callers MUST still inspect the returned call's
`return_type` to determine successful contract execution. An error tuple returned
by `wait_tx/1`, a missing height, or an unrecognized return type is not confirmation.

The uncertain result's `Reason` can now be a sanitized outcome map containing
`status`, `tx_hash`, optional `submission`, and
`reason => transaction_confirmation_unavailable`. Exception paths use stable
atoms and retain the hash once it is known. Code should treat `Reason` as a term,
not assume it is the old formatted binary.

The staged sponsored helper rejects identical caller and payer accounts before
submission (`payfor_signer_is_payer`). Use a direct account call for this case;
this wrapper does not implement sequential inner/outer nonce allocation for one
account. Account-address-only calls retain `{keypair_required, Account}`. A
malformed keypair object is no longer echoed in error results.

## Submission evidence is not a chain result

Tracked outcomes may now include an optional `submission` diagnostic. For example,
an explicit submitting-node nonce error with no mined receipt produces HTTP 202:

```json
{
  "ok": true,
  "status": "submission_unknown",
  "token_id": 42,
  "from": "ak_sender...",
  "to": "ak_recipient...",
  "tx_hash": "th_locally_calculated...",
  "submission": {
    "stage": "submission",
    "status": "node_rejected",
    "http_status": 400,
    "error_code": "nonce_too_high"
  }
}
```

The top-level status is deliberately NOT `rejected` or `not_submitted`. It does
not establish that an identical transaction was never accepted elsewhere or
cannot later be observed. The only hash queried is the locally calculated hash,
not a mismatching hash received in the acknowledgement.

A matching acknowledgement preserves the existing outcome shape without the
optional diagnostic. A later mined receipt overrides the overall status, while
any earlier submission diagnostic remains evidence of what happened at POST:
a response can have top-level `confirmed` with an earlier `submission.status`
of `node_rejected`. A mined revert has top-level `rejected`, execution stage and
the same transaction hash.

### Observation policy

The fast path requires **HTTP 400 AND a recognized nonce machine code**. These
codes are the existing shared nonce classifier's binary forms:

```text
nonce_too_high
nonce_too_low
nonce_already_used
account_nonce_too_high
account_nonce_too_low
```

This path performs a single read-only receipt request, without the full mining
poll loop. That request is bounded by the existing AE request timeout. No retry,
nonce change, fee change or rebroadcast is triggered by this decision.

Unknown codes, other 4xx responses, throttling, 5xx responses, transport errors
and malformed acknowledgements remain uncertain and use the existing receipt
wait. A `tx_rejected` tuple alone is never interpreted as a final rejection.
The conservative full wait can still hold the account locks until the configured
receipt timeout.

### Public diagnostics

`submission.status` is one of `node_rejected`, `http_error`, `invalid_ack`,
`unavailable` or `unknown`. Error codes are restricted to the five recognized
nonce codes above, plus locally generated diagnostic codes:

```text
missing_hash
hash_mismatch
transport_unavailable
session_unavailable
post_exception
unexpected_response
unknown_error
```

An unknown backend code becomes `unknown_error`; free-text reasons, response
bodies, headers and arbitrary map fields are never forwarded. `http_status` is
included only when it is an integer in 100..599. The HTTP layer repeats the
allowlisting rather than encoding the backend's diagnostic map directly.

## Regression coverage

The delivery includes all three transfer test modules, with the earlier tests
and new checks for both shared locks at prepare/POST/receipt stages, returned
polling errors, hash retention, one-POST behaviour, nonce-specific single probes,
conservative observer selection, mined-receipt precedence and diagnostic redaction.
Callback seams remain private in production and are exported only under `TEST`.
No request or application configuration can inject them.

Run from the repository root:

```bash
rebar3 eunit \
  --module=damage_ae_transfer_tests,damage_release_nft_transfer_tests,damage_releases_http_transfer_tests
```

These are unit/callback tests, not a live-chain test of signing, submission or
mining. Compilation and execution must be performed in the project's Erlang
build environment; they were not run in the delivery environment.

## Remaining operational limits

Locks serialize participating local/connected-node code only. They are not a
durable pending-nonce reservation and do not coordinate independent external
wallets. An unresolved result, process loss or lost HTTP response must be
reconciled before retrying. This patch adds no durable idempotency store or
exactly-once guarantee, and successful wallet preparation reserves neither
ownership nor a nonce.
