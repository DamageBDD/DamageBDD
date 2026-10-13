# Funded indexing pool: dashboard, participation and settlement

## Status and trust boundary

This update connects the existing desktop shard-indexing and Lightning reward
ledger to a minimal node-admin dashboard. It is a **permissioned implementation
candidate** for an existing, trusted Erlang cluster and shared artifact storage.
It is not public worker enrollment, a trustless computation market, a channel
escrow, or an on-chain smart contract.

Deployment must first pass Erlang compilation, EUnit, private multi-node indexing
and CLN regtest settlement/restart tests. The browser tests use simulated server
responses. They cannot validate Erlang authentication, worker execution or money
movement. Real payments and channel operations were not run during preparation.

The coordinator is custodial: a creator pays a normal funding invoice to its
CLN node. The reward ledger reserves accounting obligations, not exclusive CLN
channel balances. Do not share the treasury with unrelated spending processes
without a common spending policy. Preserve the DETS ledgers and CLN payment
history together; do not restore one independently after settlements.

## Minimal operator workflow

1. Configure the coordinator and approved worker nodes, then restart the affected
   ECAI services. Sign in through DamageBDD as a configured `damage.node_admins`
   account. Open `/dashboard#network` (sidebar: **Funded indexing**).
2. Under **Your indexing pool**, select an operator-allowlisted node and click
   **Add node**. That node must have explicitly opted into this coordinator and
   have working CLN. No channel is opened and no sats are sent by enrollment.
3. Choose a prepared segment plan. **Prepare segments from an existing job** can
   split source records from a paused/canceled/failed/completed `wikipedia_jsonl`
   or `yelp_ndjson` job. Completed Wikimedia jobs can supply their normalized
   record artifact. All source paths must be within the shared root.
4. Set the maximum total in whole sats and select participating nodes. Advanced
   settings choose unpaid coordinator verification or paid peer verification,
   the per-payout fee cap and the creator's external LN refund node.
5. **Calculate reward split** returns a server-computed quote, per-segment prices
   and projected earnings by participant. Changes to any input invalidate it.
   **Create contract & funding invoice** freezes the quote and starts invoice
   creation. Creation is idempotent; a failed browser response retains its key.
6. Open the funded-job accordion, pay the funding invoice from an external
   Lightning wallet, and wait for CLN-confirmed funding. Nothing is dispatched
   merely because the browser reports that an invoice was paid.
7. Click **Start**. Without the automatic-payout checkbox, work and verification
   proceed but earned rewards remain unpaid. With both server payments enabled
   and explicit per-job payout consent, accepted segment rewards are invoiced and
   paid through the existing reward ledger. Start can resume an indexed job later
   to settle its outstanding rewards.
8. The same panel shows verification progress, allocations, earned/paid rewards,
   payment hashes, merged-index search and contract export. **Pause** revokes new
   coordination/payment work. Already-dispatched jobs and submitted CLN payments
   may finish; their obligations are not discarded.

The source-preparation panel does not download arbitrary URLs or accept browser
filesystem paths. The paid dashboard workflow currently begins with normalized
source records. The existing `ecai_wikimedia_work` upstream preprocessing API
remains separate; this UI does not automatically price/distribute all Wikimedia
catalog, download, selection and extraction phases.

For an existing operator-created shard plan, import it instead of creating a
placeholder source job:

```erlang
{ok, PlanInfo} = ecai_index_pool:register_plan(
    <<"YOUR_AUTHENTICATED_NODE_ADMIN_ACCOUNT">>,
    "/srv/ecai-share/my-plan/plan.etf"
).
```

Use the actual filename returned by `ecai_index_shards:plan/3`. The import checks
plan identity and source hashes and rejects a plan with existing dispatch
receipts. This function is an operator-shell API, not an HTTP path import.

## Fair, deterministic reward arithmetic

Prices are based on each segment's **pinned source bytes**, not its worker's
self-reported CPU time or chosen number of output files. The plan and segment
identities are frozen before work. Adding a second node identity does not create
more work or increase the total budget. Assignments rotate over selected nodes;
a larger accepted segment earns more than a smaller one.

For budget `B` sats, `N` segments, fee cap `f` sats per payout and verifier share
`v` percent (zero means unpaid coordinator verification):

```
payout_roles = 1 if v = 0, otherwise 2
fee_reserve  = N * payout_roles * f
reward_pool  = B - fee_reserve
verify_pool  = floor(reward_pool * v / 100)
index_pool   = reward_pool - verify_pool
```

Each reward pool is apportioned across segment weights with the largest-remainder
method. Start with `floor(pool * weight / total_weight)`, then distribute the
remaining single sats by descending fractional remainder, breaking ties by the
lexicographic segment ID. No floating-point arithmetic is used. The resulting
prices are stored as integer millisatoshis in the existing ledger.

For example, ten equal segments, a **10,000-sat** budget, one-sat fee caps and
unpaid coordinator verification produce 9,990 sats in worker rewards (999 per
segment) plus 10 sats in fee reserve. At a 20% verifier share, reserve 20 sats
for twenty payouts, split 9,980 into 7,984 indexing sats and 1,996 verification
sats, then apportion each pool deterministically. Projected earnings assume all
work is accepted; they are not an unconditional promise of payment.

Reject budgets that cannot reserve all quoted rewards/fees or give each paid
role at least one sat. Actual routing fees are charged at settlement; unused fee
reserve stays in the campaign. Worker price quotes cannot change mid-contract. The creator wallet’s fee for
paying the initial funding invoice and any operator channel-funding/on-chain
fees are outside this payout budget.
The policy is transparent and reproducible, but source bytes are a cost proxy,
not a claim that all records have equal indexing complexity.

## Participation contract and channel state

`ecai-index-participation/v1` is an **off-chain durable contract record** containing
creator, plan identity, total budget, per-segment prices, indexer/verifier
assignments, pipeline fingerprint, LN identities/network, refund destination,
verification policy and frozen node-consent records. Its canonical SHA-256 is
required when starting or pausing work. Creation, assignments and control state
are synced to DETS before related effects. The existing reward ledger journals
funding, reservations, evidence, decisions and settlement.

The coordinator issues a random challenge when adding a node. The participant
signs a domain-separated hash binding its DamageBDD account, LN node ID, Erlang
node name, pipeline fingerprint, network, coordinator and nonce. The coordinator
uses CLN `checkmessage` with an explicit pubkey and requires verified=true plus
the same pubkey. This proves LN signing-key control; it does not prove hardware
independence, honest computation or globally unique human ownership.

The two additive DamageBDD facade calls are:

```erlang
damage_cln:sign_index_pool_message(Message).
damage_cln:check_index_pool_message(Message, Signature, Pubkey).
```

They reuse the existing CLN transport and secret/rune management. There is no
HTTP arbitrary-signing endpoint. The allowed message shape is the 19-byte
`ecai-index-pool:v1:` prefix followed by a 64-byte commitment.

**Refresh channel observations** uses uncached `damage_cln:list_peerchannels/0`.
The panel records current channel IDs, peer identity, connectivity, channel
state and available send/receive estimates with an observation timestamp.
These are observations, not an HTLC reservation, escrow balance, route-success
guarantee, or a continuous history of channel transitions. Direct channels are
optional: routed Lightning payments may work without one. This code never calls
fundchannel, close, splice, rebalance or push_msat.

Export combines the frozen contract with execution/settlement state and the
latest channel observations. No contract deployment transaction is required.
Public anchoring could commit the contract/receipt hashes later, but an on-chain
hash would not itself verify the off-chain work or control CLN funds.

## Independent verification and remote execution

Only preconfigured node atoms can be selected; HTTP input never creates Erlang
atoms. Workers must opt into the exact coordinator and advertise the same
indexing pipeline fingerprint. Erlang distribution is administrative trust, not
sandboxing. Never expose it publicly or share its cookie with arbitrary miners.

A campaign chooses fixed nodes before the first dispatch. Each segment builds
into its own server-derived output directory. Enqueue keys bind campaign,
segment and role, so an uncertain RPC cannot move that work to a new node or
create a second reward allocation. There is no automatic reassignment on failure.

The coordinator obtains the completed child job, checks its specification,
expected snapshot location and source SHA-256, then performs an independent
verification build on the coordinator or a different selected peer. It compares
canonicalized full snapshot contents (records, postings, document-frequency
counts, tags, roots, document mappings, options and sequence), sorting ETS rows
to avoid treating table iteration order as a difference. Both identity and source
checks are repeated before accepting the verdict.

A hash supplied by a worker alone is not accepted as correctness evidence.
Independent recomputation checks equivalence under the pinned pipeline, not
semantic truth, global corpus completeness, or absence of a common software bug.
Two colluding administrators in the same trusted cluster are outside this trust
model. Shared storage must have controlled OS access; hash/path checks do not
make a shared-cookie cluster safe for hostile peers.

The default verifier is the coordinator (no verifier reward). Paid peer
verification requires different accounts and different LN keys for the two roles.
A negative verified result earns only the quoted verifier reward, not the index
reward. A rejected segment prevents publication of a complete merged manifest.
The existing logical shard merge/search is reused: scores remain shard-local,
not globally calibrated IDF ranking.

Default input splits are at most 8 MiB or 1,000 lines, with a 2 MiB maximum record,
up to 256 segments per contract. The snapshot reader caps compressed and expanded
ETF bytes at 64 MiB and rejects symlink/path escapes, duplicate table keys and
empty indexes. This is not a formal bound on total BEAM heap use: decoded terms,
sorting and independent verification need additional memory. Keep worker queue
concurrency at one initially and measure on the intended desktops.

## Configuration and prerequisites

`priv/config/index_pool.example.config` is disabled and contains placeholders.
Merge only its relevant entries into existing application configuration; do not
replace sys.config or expose a wallet's runes/private keys in the dashboard.

Coordinator requirements:

- Existing DamageBDD account login and `damage.node_admins` membership.
- Existing CLN setup and reward ledger; `index_rewards_enabled=true` and
  `index_pool_enabled=true` after validation. Pool administration does not depend
  on the separate code-repair `code_admin_enabled` switch.
- `indexing_worker_nodes` contains the exact private worker node atoms.
- Same absolute `index_pool_shared_root` mount on coordinator and workers.
- `index_rewards_config` pins the coordinator's real CLN node ID, network and
  maximum budget/fee. Keep payments_enabled=false and allow_mainnet=false during
  initial checks. The default xpay adapter sets maxdelay; use a CLN version
  supporting those options (25.02+ for that configuration), and regtest first.

Each worker requires:

```erlang
{index_pool_participant_enabled, true},
{index_pool_account, <<"WORKER_DAMAGEBDD_NODE_ADMIN_ACCOUNT">>},
{index_pool_coordinators, ['damage@coordinator']},
{index_pool_shared_root, "/srv/ecai-share"},
{index_pool_min_reward_msat, 1000},
{index_jobs_max_concurrency, 1}
```

That account must belong to that worker's DamageBDD node_admins. Each worker uses
its own CLN node for signing and invoices; the coordinator uses its own treasury
for funding and payments. Workers do not need their own reward ledger enabled.
Use mutually authenticated private distribution/network controls and consistent
code versions. Connected node access is NOT granted by entering a URL in the UI.

Permit only the needed CLN operations in existing runes: participant signmessage,
invoice and listinvoices; coordinator checkmessage, getinfo, listpeerchannels,
invoice/listinvoices, decode, listpays and the selected payment method. The
coordinator's read-only rune must permit checkmessage; no CLN credentials are
returned through the new API.

## Payment grants, recovery and refunds

All HTTP changes validate the explicit DamageBDD OAuth bearer token itself via
`damage_auth:resolve_oauth/2`; a fabricated header cannot inherit authority from
an ambient cookie. Cookie-only sessions are read-only. Owner checks gate changes
to a campaign, and node-admin membership is checked again while coordinating.
Starting paid execution requires both payments_enabled=true and the explicit
`start and pay verified segments` confirmation, bound to the frozen quote hash.

The existing ledger reserves rewards and maximum fees before work allocation,
checks invoice payee/amount/network/description/expiry, persists payment intent,
and reconciles CLN by payment hash. Unknown outcomes retain their reservation.
No generic pay/xpay fallback, new invoice after an attempted payout, automatic
channel operation, or blind payment resend is added.

Coordinator background tasks are linked and monitored; shutdown stops them.
Already authorized campaigns resume after restart using durable state; reopening
the browser does not grant authority. Pause or disabling the pool revokes future
work/payment coordination, but cannot reverse already-submitted remote work or
CLN payments. A bounded active grant is not an unlimited standing treasury grant.

Worker/verification failures stop that campaign with diagnostic state. Restore
the assigned node, inspect its child job, and retry that same job from its node's
indexing dashboard when appropriate. Then Start the funded campaign again. Do
not create replacement work or move an uncertain dispatch silently.

For settlement ambiguity use **Check funding / settlement**. It does not submit a
new payment. A definitively retryable payment, expired invoice, contradictory
proof or quarantined ledger requires operator review; do not clear reservations
to make the UI advance. Existing operator settlement APIs remain available for
that recovery. This version does not offer public disputes/arbitration or a
peer-replacement protocol.

To return unused balance, pause, resolve outstanding submitted work, and use
**Reserve refundable balance**. Only unencumbered funds are refundable. Generate
an invoice on the pinned external refund wallet with the exact displayed amount
and description; paste it into **Pay refund**. Fees remain bounded. Earned and
uncertain payments remain reserved, and a nonrefundable residual is not silently
sent elsewhere. Creating a refund does not cancel existing submitted work.

## API and checks

New routes are scoped under `/ecai/admin/index-pool`:

- GET status; POST nodes, prepare, channels, quote, jobs.
- POST jobs/:id/start, pause, reconcile, refund, refund-pay, search.
- GET jobs/:id/contract.

The dashboard catalog includes all thirteen routes. Response booleans are real
JSON booleans, and ECAI's existing codec externalizes nested values consistently.
Status polling is visible-view-only at ten-second intervals. Coordination uses
one monitored background step at a time (default one-second tick, configurable
250–30,000 ms), with at most two active segment phases by default. Existing worker
queue limits still govern resource use.

```bash
node --check apps/ecai/priv/static/js/ecai-index-pool.js
node --check apps/ecai/priv/static/js/ecai-console.js
python3 apps/ecai/test/test_console_contract.py
python3 apps/ecai/test/test_indexing_rewards_contract.py
python3 apps/ecai/test/test_index_pool_contract.py
python3 apps/ecai/test/test_index_pool_browser.py   # Playwright + Chromium
rebar3 compile
rebar3 eunit --app ecai
```

Twenty-four new EUnit test functions cover allocation conservation and tie
breaking, price-table reservation/acceptance, legacy contracts, verification
canonicalization, compressed snapshot limits and path/node allowlists. They
require Erlang execution and are not replaced by static Python checks.

Before real use, test a three-node regtest campaign: creator/coordinator,
indexer and optional paid verifier. Test funding, full rebuild comparison,
settlement/preimage/fee accounting, coordinator and worker restart, a lost
payment response, same-hash reconciliation, revoked grants, rejected segments
and refund. Validate actual DamageBDD OAuth tokens against the new HTTP handler,
including a valid cookie plus an invalid bearer. The mocked browser test only
checks how the UI responds to those simulated authorization outcomes.
