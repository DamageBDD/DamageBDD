# Inference receipt inspection and explicit recovery

## Baseline and scope

Apply this incremental patch AFTER `ecai-timeout-ui-fixes.patch`, or after all
three patches in that earlier series. The baseline is the uploaded
`latest-ecai.tar.gz` plus that series. Do not apply both versions of the earlier
patches. This follow-up changes the pool, the vulnerability monitor's log
classification, and adds regression tests. It does not change the provider UI
or introduce a browser-accessible receipt mutation route.

A failure tuple ending in `uncertain` is returned when an already-persisted
receipt blocks a repeated request. This path releases the checkout lease and
returns before the provider client is invoked. A tuple ending in
`ollama_request_failed` is the initial transport failure classification. Neither
value proves whether an earlier provider execution consumed usage or incurred
charges. The same fingerprint survives a restart; larger transport/queue
budgets do not remove the receipt.

The new monitor warning explicitly identifies a persisted receipt block and
says that no new provider request was sent. The scan remains unsuccessful and
its error is still persisted; the patch does not silently mark a blocked scan
as completed or clear findings.

## Read before retrying

Use the trusted Erlang shell AFTER rebuilding and a controlled restart:

```erlang
ReceiptId = <<"cec622937c893a25c4707cd52096b971f41bc0576a96f623561a5c84fbb95e3d">>.
ecai_ollama_pool:inference_receipt(ReceiptId).
```

This performs an exact-key lookup and returns an allowlisted view. It excludes
cached response values, client metadata, prompts, credentials, headers, and raw
provider bodies. Existing pre-patch receipts are treated as attempt 1. If an
older receipt only contains `error => ollama_request_failed`, detailed transport
information cannot be reconstructed. The previous diagnostics patch writes
`error_detail` for future failures; look for its `phase` and `reason` fields.

Before rebuilding, the equivalent read-only diagnostic is:

```erlang
ReceiptId = <<"cec622937c893a25c4707cd52096b971f41bc0576a96f623561a5c84fbb95e3d">>.
case dets:lookup(ecai_inference_receipts_dets, {inference_receipt, ReceiptId}) of
    [{_, R}] -> maps:with([request_id, status, attempt, provider, node_id, model,
                          role, created_at, sent_at, uncertain_at, error,
                          error_detail], R);
    [] -> not_found;
    {error, Why} -> {error, Why}
end.
```

Do not dump the entire DETS table, delete the receipt file, use a bulk reset,
turn off `billing_sensitive`, or change request fingerprints just to bypass the
receipt guard. The approval API is not a remedy for an ongoing provider outage.

## Approve one reviewed uncertain attempt

Use this only after investigating the original failure and deciding that a new
execution is justified despite possible duplicate inference usage/cost. Review
the returned receipt first; do not put inspection and approval in an automatic
loop. Approval itself does not contact the provider, but the next matching
background request can use it immediately.

```erlang
{ok, ReceiptForReview} = ecai_ollama_pool:inference_receipt(ReceiptId).
```

After reviewing that result and accepting the risk:

```erlang
ecai_ollama_pool:approve_inference_retry(
    ReceiptId,
    maps:get(attempt, ReceiptForReview),
    accept_duplicate_inference_cost
).
```

Successful approval changes only that receipt to `retry_approved`, advances the
attempt number, and appends the prior sanitized attempt plus approval timestamp
and calling BEAM node/PID to its history. The caller PID is operational metadata,
not authenticated attribution to a human administrator. No user/HTTP access is
provided by this patch; these are trusted BEAM APIs.

The next matching claim changes `retry_approved` to `claimed`; concurrent claims
are blocked. It then follows the existing `sent -> completed | uncertain`
workflow. A confirmed pre-send failure restores the approval so existing safe
endpoint failover can proceed without erasing the earlier history. Another
ambiguous failure requires a new approval for the new attempt number.

The caller must provide the attempt number it actually reviewed. A command for
an older attempt cannot approve a later uncertain attempt. Repeating an
approval while the receipt is already `retry_approved`, `claimed`, `sent`, or
`completed` does not authorize another attempt. Re-inspect on timeout or a
storage error rather than assuming the operation failed without any effect.

There is intentionally no automatic receipt expiry, blanket approval, automatic
retry of a `sent` record, or retry-after-age policy. Orphaned `claimed`/`sent`
receipts require separate investigation; this API does not force their recovery.

## What this does NOT establish

This patch does not retrieve a response lost upstream, prove that earlier usage
was uncharged, cancel work still running remotely, or fix the initial network or
provider failure. If an approved attempt fails again, inspect the newly written
`error_detail` and stop authorizing retries until that cause is understood.

Request fingerprinting is unchanged. Approval applies to the matching
provider/model/role/prompt/output-options fingerprint, not to every audit or to
a newly selected model. The existing successful-response cache is retained.

## Build and validate in the full checkout

```bash
git apply --check "$HOME/Downloads/ecai-receipt-recovery.patch"
git apply "$HOME/Downloads/ecai-receipt-recovery.patch"
git diff --check
rebar3 compile
rebar3 eunit --module=ecai_inference_receipt_recovery_tests,ecai_llm_pool_reload_tests,ecai_inference_diagnostics_tests
python3 apps/ecai/test/test_inference_status_recovery_contract.py -v
```

Drain active inference before a controlled restart. The follow-up does not alter
the pool record layout, but its receipt reservation semantics change. Keep all
existing receipt and learning-store data.

## Validation performed for this delivery

- Incremental patch application, resulting contents, reverse application, and
  whitespace checks are verified against a reconstruction of the stated baseline.
- The existing inference/status recovery static suite passes: 8 checks.
- The existing LLM settings static suite has 9 passing checks; its Damage bridge
  check cannot run because the archive lacks `apps/damage/src/damage_ai_ecai.erl`.
- Twelve new EUnit cases cover legacy inspection/redaction, required explicit
  acknowledgement, stale/invalid attempts, rejection of non-uncertain states,
  single-use approval, history preservation, successful caching, persistence
  across DETS reopen, invalid identifiers, missing receipts, unknown states,
  and concurrent claim exclusivity.
- Erlang compilation and EUnit execution were NOT performed here: Erlang/Rebar3
  are absent and package installation was unavailable. These tests must be run
  in the full project before deployment. Power-loss/disk-failure injection and
  live provider billing or generation tests were not performed.
