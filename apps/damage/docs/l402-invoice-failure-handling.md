# L402 invoice timeout and invalid-result handling

## Symptom and diagnosis

The supplied 2026-10-21 log shows two separate events:

1. `cln:create_invoice/4` exits from a `gen_server:call/2` timeout.
2. `damage_cln` converts the exit to `{error, {cln_unavailable, Reason}}`, but
   `damage_l402:challenge_with_body/4` treats that tuple as an invoice map.
   The resulting `badmap` reaches `damage_http:handle_l402_challenge/3`.

In the supplied `latest-damage.tar.gz`, all four `create_invoice` clauses use
`gen_server:call/2`, whose default timeout is 5000 ms. The invoice HTTP path
previously used damage_gun's longer default connection/response waits. The
`600` argument in the log is invoice expiry in seconds, not an RPC timeout.

The existing HTTP code already converts a returned `{error, Reason}` into
503 with `L402_UNAVAILABLE`, `Retry-After: 5` and `Cache-Control: no-store`.
No production change to damage_http is needed. Locked-secrets classification
is retained. This patch does not make `/status` public or bypass payment.

## Changes

### damage_l402

- Propagate facade error tuples without accessing them as maps.
- Accept successful map and `{ok, Map}` replies, with atom or binary keys.
- Validate invoice text and a 64-character hexadecimal payment hash before
  storing anything in any of the three L402 ETS indexes.
- Reject incomplete/malformed replies and RPC error objects without including
  backend response bodies in the returned diagnostic.
- Reject expired/malformed `expires_at`; cap token expiry to the earlier of the
  backend expiry and the requested validity window.
- Add `Cache-Control: no-store` to successful 402 challenges.

Invoice text validation is structural/header-safety validation, not independent
verification of a BOLT11 signature. The established CLN backend remains trusted.

### cln

- Use an explicit gen_server call timeout for every create_invoice overload.
- Bound pool checkout, connection establishment, total response headers/body,
  and response size specifically for invoice creation.
- Snapshot timeouts for each call and pass a monotonic deadline to the worker.
  An already-expired queued invoice request fails without sending HTTP.
- Disable Gun connection retries for invoice creation; there is no automatic
  second invoice RPC after an ambiguous failure.
- Reject non-2xx invoice HTTP results and malformed JSON safely.
- Preserve the old five-element request shape for already-in-flight calls.
- Leave payment, hold-invoice, channel-management and other RPC budgets alone.

This uses the bounded-response support already present in the uploaded
`damage_gun.erl`; there is no new transport dependency.

## Configuration

Optional entries inside the existing `damage` application proplist in sys.config:

```erlang
{cln_invoice_checkout_timeout_ms, 1000},
{cln_invoice_connect_timeout_ms, 5000},
{cln_invoice_http_timeout_ms, 10000}
```

Each setting accepts an integer from 1 through 60000 ms. Other values fall back
to the documented default; `infinity` is deliberately unsupported here.

The default worker call timeout is 16000 ms: 5000 ms connection allowance +
10000 ms total response allowance + 1000 ms reply margin. Pool checkout is
separate and defaults to 1000 ms. Response size is capped at 65536 bytes.
Queued requests have their remaining transport budget reduced. These are
software time budgets, not real-time scheduling guarantees.

No settings are required to enable the fix. Do not use the generic ten-minute
CLN timeout to make a failed invoice endpoint appear healthy.

## Apply and test

From the full monorepo root:

```sh
PATCH="$HOME/Downloads/damagebdd-l402-invoice-timeout.patch"
git apply --check "$PATCH"
git apply "$PATCH"
rebar3 compile
rebar3 eunit --module=damage_l402_challenge_tests
rebar3 eunit --module=cln_invoice_timeout_tests
```

The tests require the project's existing Meck and JSON dependencies. Run them
in an isolated test VM, not against a running node: they mock shared modules
and own their L402 ETS tables. No test sends a real invoice, signs a payment,
or connects to a Lightning backend.

Use your normal rebuild/reload or restart procedure for both changed modules.
For an already-running `rebar3 shell` after a successful development build:

```erlang
code:load_file(cln).
code:load_file(damage_l402).
```

No worker state record change is required. A previously-started request may
still be using the old code/timeouts until it finishes. Do not force-purge a
worker that may be processing a payment just to accelerate this update.

## Diagnose the remaining backend delay

The patch fixes the incorrect error handling and mismatched budgets. It cannot
prove why the CLN worker failed to reply from this log alone. Possible causes
include a queued/occupied worker, CLN REST latency, a connection or TLS issue,
proxy routing, or a slow/unavailable CLN daemon.

In the same Erlang shell, while the PID from the log still exists:

```erlang
damage_cln:status().
erlang:process_info(pid(0, 4256, 0), [
    status, current_function, current_stacktrace, message_queue_len, reductions
]).
```

Take another process-info sample during a failing request to distinguish a
long-running call from an idle worker. Avoid dumping `sys:get_state/1` or
mailbox contents into public logs: the CLN worker state contains runes.

On the CLN host, use the correct network/lightning-dir options for your setup:

```sh
lightning-cli getinfo
lightning-cli listinvoices 'EXACT_L402_LABEL_FROM_THE_LOG'
```

A caller timeout is not evidence that no invoice was created. Query the label
before manually repeating the operation. If the local CLI is responsive but
the Erlang REST request is slow, investigate the REST listener, route, TLS,
proxy selection and worker queue rather than restarting all payment services.

## Validation status

The deliverable includes focused EUnit regression tests for the original
failure, malformed replies, successful reply shapes, 402/503 behavior, locked
secrets, response sanitization, expiry, timeout configuration, expired queued
requests, HTTP status handling, and a reply later than the old five-second
caller limit.

Erlang/OTP and rebar3 were unavailable in the editing environment; compilation
and EUnit execution have NOT been performed. Patch application and source
consistency checks are recorded in the accompanying validation report. No live
CLN outage diagnosis or payment/invoice operation was performed.

## Primary references

- Erlang/OTP gen_server reference: https://www.erlang.org/doc/apps/stdlib/gen_server.html
- Core Lightning invoice: https://docs.corelightning.org/reference/invoice
- Core Lightning listinvoices: https://docs.corelightning.org/reference/listinvoices
