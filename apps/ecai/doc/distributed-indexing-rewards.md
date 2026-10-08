# Distributed indexing and Lightning rewards: permissioned pilot

## Scope and safety status

This change adds operator APIs, not a public worker marketplace or new browser
payment controls. It extends the previous `ecai-eunit-desktop-sharding-updated`
source. The DamageBDD facade changes are a separate additive patch based on the
inspected Library `damage_cln.erl` and `cln(1).erl`; verify those hunks against
your actual umbrella repository rather than replacing the complete modules.

**Erlang compilation, the new EUnit tests, multi-node execution and regtest
Lightning settlement have not been executed in the development container.**
Only source-contract tests, JavaScript syntax and patch replay were executable.
Treat this as an implementation candidate for a permissioned regtest pilot,
not an audited money-handling release. Keep both the feature and payments off
until the deployment checks at the end pass. No channel or payment was created
while preparing this change.

The existing code-review publication gates and experimental marketplace are
unchanged. Indexing rewards are Bitcoin millisatoshi bookkeeping, not DAMAGE
balances, NFTs, exchange conversions or L402 authorization invoices.

## 1. Work granularity

The upstream work plan has five dependency-ordered stages:

| Stage | Schedulable unit | Dependency |
|---|---|---|
| Pageviews | One compressed month source | Pinned source catalog |
| Aggregation | One page-ID hash partition across all months | All month units |
| Selection | One bounded top-K merge | All aggregation partitions |
| Content | One Cirrus content shard | The global selection |
| Ranked output | One final selected-record pass | All content shards |

`ecai_wikimedia_work:index_plan/3` then passes the selected JSONL files to the
existing byte/line-bounded shard planner. Each child index uses a private search
context, produces a snapshot, and can be combined through
`ecai_index_shards:merge/2`. Its merge remains a logical manifest: shard-local
ranking is not globally calibrated IDF, and commitments do not prove global
search completeness.

The global selection barrier is intentional. Independently choosing top-K
articles in every content shard would change the selection policy. Pageview
months and compressed Cirrus files are streamed as complete decompression
units; the code does not pretend arbitrary bzip2 byte offsets are resumable.
An upstream source unit can still take a long time and consume substantial disk.
The new boundaries primarily reduce peak memory, isolate retries and expose
parallelism. Pause/cancel may wait until that unit returns to the worker loop.

Desktop defaults are conservative: 128 aggregation partitions, 200,000 pages
per aggregation table, a 128 MiB table threshold, 4 MiB input-line limit,
50,000 maximum candidates, 250 output records per intermediate file, and a
16,777,216-word worker heap ceiling. On a 64-bit BEAM the heap ceiling alone is
128 MiB; it excludes ETS, reference-counted binaries and external processes.
The table guard checks before/after updates and can overshoot by one record.
These are NOT cgroup limits or a complete process RSS/disk/time budget.

A partition that exceeds its cap fails explicitly; it does not discard records.
Increase the partition count in a NEW immutable plan, reduce the selection
size, or adjust an assessed memory budget. Existing monolithic jobs keep their
previous defaults unless they opt into the new limits.

## 2. Local versus multi-node execution

Local-only operation is the default. To use desktop workers, configure the
coordinator's `ecai.indexing_worker_nodes` with pre-existing Erlang node atoms:

```erlang
{indexing_worker_nodes, ['damage@desktop-a', 'damage@desktop-b']},
{wikimedia_work_dir, "/srv/ecai-share/wikimedia-work"},
{index_jobs_max_concurrency, 1},
```

All workers need the same ECAI version, dependencies, source/output paths and
work-root configuration. This pilot uses an existing **trusted private Erlang
cluster and shared storage**. It does not provide Internet worker discovery,
artifact upload/download, public claim authentication, fencing consensus or a
cross-node dashboard. Do not expose Erlang distribution to untrusted workers.
Protect plan/receipt files with operator-managed filesystem permissions.

`ecai_index_dispatch` records a worker node before calling that node's existing
`ecai_index_jobs_srv`. An ambiguous enqueue is retried against that same node
and idempotency key, never silently assigned elsewhere. Existing local shard
receipts continue to work. Losing a node or its queue database requires operator
recovery; this is not an automatic lease-expiry/reassignment protocol.

The coordinator's work status queries the child queues. Existing dashboard
pages display the jobs belonging to the node being viewed. A remote job's
runtime telemetry is available on that worker's existing dashboard.

### Plan and submit a bounded window

Run this from an authorized operator shell. Source dates are illustrative;
planning must resolve actual available catalog files before anything is queued.
Use a real registered creator account in place of the placeholder.

```erlang
Creator = <<"REPLACE_CREATOR_ACCOUNT">>.
WikiSpec = #{
    kind => wikimedia_visibility,
    owner => Creator,
    source => #{
        project => <<"simplewiki">>,
        pageview_project => <<"simple.wikipedia">>,
        content_release => latest,
        pageview_months => [<<"2026-08">>, <<"2026-09">>]
    },
    target => #{mode => live_search,
                base_dir => <<"/srv/ecai-share/index">>},
    options => #{limit => 10000, minimum_active_months => 2},
    finalize => #{build_nft_manifest => false, publish_ipfs => false}
}.
{ok, WorkRoot, WorkPlan} = ecai_wikimedia_work:plan(
    WikiSpec, #{partitions => 128, max_partition_pages => 200000}).
{ok, Dispatches} = ecai_wikimedia_work:enqueue_ready(WorkRoot, 16).
ecai_wikimedia_work:status(WorkRoot).
```

`Dispatches` contains independent `{ok, Placement}` or `{error, Reason}` entries;
check partial failures. Call `enqueue_ready/2` again as dependencies complete.
It will not automatically retry failed/canceled queue jobs. Use the existing
worker-node retry API for those job IDs. No background scheduler is installed
by this patch.

An abruptly killed upstream worker can leave its exclusive output lock behind.
After confirming the failed unit, the operator can request:

```erlang
ecai_wikimedia_work:clear_stopped_unit_lock(WorkRoot, UnitId).
```

This checks the recorded worker PID on its pinned node and refuses to clear a
live or unreachable worker's lock. Then retry the existing queue job. Empty,
corrupt, plan/dispatch/recovery locks need manual investigation and fencing;
never delete a lock simply because it is old. Shared storage must support the
exclusive-create and atomic-rename semantics used here.

### Convert ranked output into mergeable search shards

After the ranked unit completes:

```erlang
{ok, ShardPlanFile, ShardPlan} = ecai_wikimedia_work:index_plan(
    WorkRoot, "/srv/ecai-share/shard-plans",
    #{max_shard_bytes => 2097152, max_line_bytes => 1048576,
      max_lines_per_shard => 250, max_files_per_job => 1}).
```

Allocate funded rewards BEFORE submitting the corresponding child work when
workers are being paid. Then submit a small window:

```erlang
ecai_index_shards:enqueue_batch(ShardPlanFile, 1, 16).
```

The same configured worker-node list is used for search shards. Source files,
snapshots and placement receipts must be visible at identical paths. Submit
subsequent windows until all entries have completed. Then:

```erlang
ecai_index_shards:merge(ShardPlanFile, "/srv/ecai-share/merged.etf").
ecai_index_shards:search("/srv/ecai-share/merged.etf",
                         #{name => <<"elliptic curve">>}, 10).
```

## 3. Job budget is not channel escrow

Three amounts must remain distinct:

- **Funded campaign budget:** settled incoming invoices recognized by this ledger.
- **Reserved rewards:** accounting liabilities assigned to work and participants.
- **Spendable channel capacity:** the CLN node's current ability to route a payment.

Reservations do not modify a channel's balance or isolate funds from other
DamageBDD spending. `ecai_index_rewards:liquidity/0` returns fresh raw
`listpeerchannels` capacities through the facade; capacity is advisory, not a
route-success promise. A dedicated treasury instance or a shared spend-control
policy across EVERY CLN spender is required before claiming treasury isolation.
This patch does not add that shared policy to unrelated DamageBDD applications.

Direct channels to worker nodes are optional; routed invoice payments can use
existing channels. If an operator deliberately opens a direct channel, the
existing DamageBDD API is:

```erlang
%% On the coordinator, only after peer connectivity, on-chain funds and fees
%% have been reviewed. This is a real on-chain funding action, not a dry run.
%% AmountSat is SATOSHIS; do NOT pass a budget_msat value to this function.
damage_cln:open_channel(WorkerLightningNodeId, AmountSat).
```

Channel opening capital and on-chain fees are outside campaign reward budgets.
The new reward code never opens, closes, pushes initial value to, or rebalances
a channel automatically. In particular, Core Lightning's `push_msat` is an
upfront gift to the peer, NOT conditional reward escrow, and is never used.

## 4. Fund and reserve rewards

Merge the provided `priv/config/index_rewards.example.config` into your existing
configuration. Keep it disabled initially. The ledger belongs to one coordinator
on local durable storage; do not use a shared DETS file across multiple owners.
Use real public CLN node IDs from each participant and the treasury. No new rune,
private key, wallet seed or direct CLN endpoint is configured in ECAI.

After compilation and mocked tests pass, configure a regtest treasury and set
`index_rewards_enabled=true`. Keep `payments_enabled=false` until the end-to-end
regtest checklist passes. `allow_mainnet=false` rejects mainnet treasury calls.
The treasury/network binding is checked on recovery; a ledger cannot silently
move to another CLN node. The creator's refund destination, indexer and verifier
are registered LN payees, not arbitrary destinations supplied during payout.

The example campaign prices a search shard at 100 sat and its verification at
20 sat, with at most 1 sat routing fee for each invoice. One accepted shard
therefore reserves **122,000 msat**, or 122 sat. Sixteen units reserve 1,952 sat.
A 2,000-sat budget leaves 48 sat unallocated before actual fee savings. These
are example rates, not market prices or measured job-cost estimates.

```erlang
Indexer = <<"REPLACE_INDEXER_ACCOUNT">>.
Verifier = <<"REPLACE_VERIFIER_ACCOUNT">>.
Pricing = #{budget_msat => 2000000, index_msat => 100000,
            verify_msat => 20000, fee_cap_msat => 1000}.
Ordinals = lists:seq(1, erlang:min(16, length(maps:get(entries, ShardPlan)))).
{ok, Contract, PaidUnits} = ecai_index_reward_contract:shards(
    ShardPlanFile, Ordinals, Pricing).
{ok, Campaign0} = ecai_index_rewards:create(Creator, <<"simplewiki-pilot-001">>, Contract).
CampaignId = maps:get(id, Campaign0).
{ok, _} = ecai_index_rewards:funding_invoice(Creator, CampaignId).
```

Funding invoice creation is asynchronous. Once `status/0` reports
`cln_operation_in_flight=false`, fetch the invoice:

```erlang
{ok, Campaign1} = ecai_index_rewards:campaign(CampaignId).
FundingBolt11 = maps:get(bolt11, maps:get(funding, Campaign1)).
```

The creator pays `FundingBolt11` using their regtest wallet. The existing
DamageBDD `invoice_paid` event is a wake-up hint; the coordinator always
re-queries the invoice by its durable label before crediting it. An event's
claimed amount is never trusted. If the event was missed, use:

```erlang
ecai_index_rewards:refresh_funding(Creator, CampaignId).
```

The namespace is `ecai-index:v1:<campaign-id>:fund`, not `damage:...`. The
inspected Damage token invoice consumer only processes its `damage` prefix;
check all invoice consumers on your actual node before using a shared treasury.

After the campaign state is `funded`, allocate each selected unit:

```erlang
UnitId = maps:get(id, hd(PaidUnits)).
ecai_index_rewards:allocate(Creator, CampaignId, UnitId, Indexer, Verifier).
```

Each allocation reserves index reward + verification reward + their fee caps.
Compute placement and payment assignment remain separate operator decisions in
this pilot: match the dispatched compute node to the registered indexer before
accepting its submission. No public proof binds an Erlang PID to an LN identity.
Insufficient budget is rejected. A declared unit list may exceed the budget's
capacity: the operator must fund enough for the intended allocations or create
additional, disjoint campaigns. This version has no top-up operation. Campaigns
are bounded to 256 units and the pilot ledger to 32 campaigns.

The same creator/plan/unit cannot be reserved or paid again through another
campaign. Canceling an unsubmitted allocation releases that claim; accepted or
rejected work keeps its claim. An indexer and verifier must have different
registered accounts AND LN node IDs. That prevents trivial self-assignment;
it is not a cryptographic proof of organizational independence or Sybil resistance.

## 5. Submit, independently verify and settle

These are **trusted operator-shell APIs**. Actor arguments are not authentication.
A future HTTP/worker protocol must derive identity from DamageBDD authentication,
not forward arbitrary JSON actor/owner fields to these functions.

After the child queue job completes:

```erlang
{ok, ResultCommitment} = ecai_index_reward_contract:shard_result(ShardPlanFile, hd(Ordinals)).
ArtifactSHA = maps:get(artifact_sha256, ResultCommitment).
EvidenceSHA = maps:get(evidence_sha256, ResultCommitment).
ecai_index_rewards:submit(Indexer, CampaignId, UnitId, ArtifactSHA, EvidenceSHA).
```

The helper checks queue completion, specification hash, original source bytes
and snapshot hash. It **does not prove** that the snapshot indexes every required
record correctly. The assigned verifier must run the agreed independent checks
or recomputation, retain the report and submit its report hash. Only then does
the creator explicitly accept that outcome:

```erlang
%% VerificationReportSHA is supplied by the actual independent verifier.
ecai_index_rewards:attest(Verifier, CampaignId, UnitId,
                         ArtifactSHA, accept, VerificationReportSHA).
ecai_index_rewards:accept_work(Creator, CampaignId, UnitId, ArtifactSHA, accept).
```

A negative verdict uses `reject` for both calls: the indexer earns nothing, but
the verifier can still earn the agreed verification fee. Set `verify_msat=0` for
index-only rewards while retaining an independent verification gate; set
`index_msat=0` for verification-only rewards. This is operator-mediated
acceptance, not trustless computation escrow. Creator non-acceptance/disputes
are not automatically arbitrated, and there is no worker collateral or slashing.

For upstream work instead of search shards, use
`ecai_index_reward_contract:upstream(WorkRoot, UnitIds, Pricing)` and submit a
verified upstream receipt hash from `ecai_wikimedia_work:verify_receipt/2` as the
artifact commitment. Schedule those units only after their assigned budget is
reserved. Different stages can use separate campaigns/prices.

### Worker invoice and creator's explicit payment

Read `campaign/1`, select the relevant payout in `payouts`, and pass its public
amount, ID and exact description to the receiving worker. On that worker's own
DamageBDD/CLN node:

```erlang
Description = ecai_index_reward_ledger:invoice_description(
    CampaignId, PayoutId, ArtifactSHA).
%% Inspect the successful result and obtain its bolt11. Do not accept an RPC error.
damage_cln:create_invoice(PayoutAmountMsat, Description, 3600, PayoutId).
```

On the coordinator:

```erlang
ecai_index_rewards:submit_invoice(Indexer, CampaignId, PayoutId, WorkerBolt11).
ecai_index_rewards:pay(Creator, CampaignId, PayoutId, <<"pay indexing reward">>).
```

For the verifier's payout, use `Verifier` and that payout's ID/amount instead.
CLN `decode` must report a valid fixed-amount BOLT11 invoice with the registered
payee, configured network, exact reward amount, unexpired lifetime and exact
campaign/payout/artifact description. Amountless invoices, arbitrary offers,
BOLT12 objects and description-hash-only invoices are not supported in this pilot.
Payment hashes are uniquely bound across all funding and payout records.

The coordinator writes and syncs the intent before invoking CLN with an
absolute `maxfee`. Use `payment_method=xpay` with CLN 25.02 or newer (this adapter also sets
`maxdelay`, introduced in 25.02).
For a node that deliberately uses the older `pay` RPC, set `payment_method=pay`
before testing; there is NO fallback between methods after a timeout. The
facade additions reuse DamageBDD's existing pooled connection, TLS and runes.
The existing readonly rune must permit `decode`, `listinvoices`, `listpays`,
`listpeerchannels` and `getinfo`; the spending rune needs the configured payment
method and invoice creation. Narrow capabilities using your existing CLN policy.

Only an authoritative completed payment with the expected amount and a valid
SHA-256 preimage is marked paid. The ledger charges actual amount sent,
including routing fees, then releases unused fee reserve. A mismatched proof
or fee overrun quarantines further creation/allocation/pay operations.

A coordinator restart never automatically resends an interrupted payment.
Pending, absent, transport-ambiguous and old failed observations keep the
obligation reserved and uncertain. An explicit error response to the current
payment invocation plus a failed CLN payment record can become `retryable`;
that still requires a new creator-authorized call with the SAME invoice.

```erlang
ecai_index_rewards:reconcile(Creator, CampaignId, PayoutId).
ecai_index_rewards:campaign(CampaignId).
ecai_index_rewards:events().
ecai_index_rewards:liquidity().
```

Campaign output includes `node_allocations`: accounting reserved amounts,
allocated reward amounts, earned/unpaid rewards, paid rewards and actual fees
by registered participant/LN node. It does not label these as channel balances.

After all outstanding work is decided or canceled, `close/2` prevents further
allocations. `refund/2` reserves only unencumbered balance (less its fee cap)
as a normal invoice-validated payout to the registered creator refund node.
Already-earned or uncertain payouts remain reserved. Expired attempted invoices
and unresolved payment outcomes are intentionally not replaced automatically;
manual accounting/reconciliation is required. No balance is silently forfeited.

## 6. Deployment gate and remaining limitations

1. Apply the CLN facade extension and ECAI patch with `git apply --check`; do not
   force hunks over a different `cln.erl`. Compile the actual umbrella app.
2. Run EUnit, including `ecai_index_reward_ledger_tests`,
   `ecai_index_rewards_tests` and `ecai_wikimedia_work_tests`. The fake CLN backend
   is test-only and must never be configured in a production release.
3. On regtest, test funded/unfunded budgets, independent verification, wrong
   payee/network/amount, depleted channels, absolute fee caps, duplicate payment
   attempts, a killed coordinator during payment and subsequent reconciliation.
4. Test real two-node source processing, private snapshot construction, data
   tampering, worker loss/lock recovery and merged search. Confirm disk quotas,
   permissions and paths. Aggregation verifies only its committed partition from each month, not
   all spool partitions repeatedly. Other stages still hash their consumed
   dependency files, so allow for integrity-check I/O as well as processing.
5. Review treasury isolation, participant registration, acceptance/dispute policy,
   backup recovery and all other CLN spenders before considering real funds.

Back up the coordinator ledger, work/dispatch receipts and CLN state consistently.
Do not recreate or roll back the reward ledger while leaving paid invoices in
CLN: within-ledger idempotency is not protection against deleting accounting
history. A DETS file is not replicated financial consensus or a tamper-proof
external audit log. Recovery from backup/quarantine and dispute arbitration need
operator procedures; no automatic release of ambiguous obligations is provided.

Remote receipt signing, public claims/leases, HTTP funding UI, acceptance
arbitration, admission quotas per tenant, adversarial verification protocols,
channel-level budget isolation, global ranking calibration and globally complete
search proofs are not implemented here.

## Primary API references consulted

Core Lightning documentation, retrieved for this implementation:
`https://docs.corelightning.org/reference/decode`,
`https://docs.corelightning.org/reference/xpay`,
`https://docs.corelightning.org/reference/pay`,
`https://docs.corelightning.org/reference/listpays`,
`https://docs.corelightning.org/reference/listinvoices`,
`https://docs.corelightning.org/reference/listpeerchannels`,
`https://docs.corelightning.org/reference/fundchannel`.

Source integration points inspected: DamageBDD `damage_cln.erl`, `cln(1).erl`,
`cln_ws_mgr(1).erl` invoice-paid broadcast and `damage_ae(1).erl` invoice namespace.
