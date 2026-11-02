# Schedule operation recovery — validation

Validation date: 2026-10-21.

## Executed

- Node.js syntax checks: `schedules-v2.js` and `schedule-operations.js` passed.
- Node.js unit tests: 22 passed, 0 failed (12 operation-observation tests and
  10 existing starter-template tests).
- Chromium starter regression fixture: 14 checks passed.
- Chromium asynchronous-operation fixture: 14 checks passed, including delayed
  confirmation, lost observation, duplicate-click suppression, pending-state
  reload, reconciliation messaging, transaction identity, mobile wrapping and
  a success message only after a completion result.
- Browser fixtures load production JavaScript/CSS and simulate API responses.
  They do not execute the Erlang backend or a real wallet.

## Included, not executed

- `damage_schedule_v2_operation_tests`: deterministic operation identity,
  payload binding, invalid keys, safe failure/recovery, public metadata redaction.
- `damage_schedule_v2_async_tests`: actual gen_server/DETS with mocked chain;
  admission/idempotency, responsive reads, owner isolation, uncertain outcome,
  restart recovery, legacy drafts and stale timer messages.
- `damage_schedule_v2_async_http_tests`: HTTP 202 and operation status, timeout
  classification, owner-scoped lookup and empty JSON arrays.

Erlang/OTP, erlc and rebar3 are not installed in this environment. Consequently
backend compilation, EUnit and end-to-end chain integration are UNVERIFIED.
Run the supplied tests in the full monorepo before deploying to a funded node.

## Patch basis

`latest-damage.tar.gz` plus the earlier starter-schedules patch. The earlier
L402 patch is compatible but is not a prerequisite. Changed-file hashes are in
`manifest.sha256` in the ZIP. Package application checks are recorded in
`patch-checks.json` in the ZIP.

No live probes, invoice generation, wallet signing, transaction submission,
funding, refunds, or automatic on-chain reconciliation were performed.
