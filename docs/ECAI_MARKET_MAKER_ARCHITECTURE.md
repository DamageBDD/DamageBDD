# ECAI market maker: technical design

For installation and operator instructions, see [ECAI_MARKET_MAKER.md](ECAI_MARKET_MAKER.md).

**Pipeline**

`Coinstore public depth + ticker → ecai_mm_feed → validation → volatility EWMA →
ecai_mm_curve → inventory/fee budgets → paper quote ledger → DETS samples →
ECAI hash chain / P-256 point → authenticated Cowboy JSON → indexed charts`

`price_feed:damage_to_sats(1)` is queried only as a secondary reference; a
missing or failing price feed produces `null`, not a made-up quote. Optionally
set `max_reference_deviation_bps` to halt when the reference price
is too far from the Coinstore book midpoint.

## Quote mathematics

With order-book mid `m`, base holdings `D`, USDT cash `U`, target inventory
weight `w*`, bounded inventory pressure `i`, EWMA volatility in basis points
`v`, and max-skew `s_max`, the algorithm computes:

```
w = D*m / (U + D*m)                 (use 0.5 if book equity is zero)
i = clamp((w - w*) / (w_max - w*), -1, 1)
r = m * (1 - i*s_max/10000)        reservation price
h = max(base_half_spread, maker_fee + fee_buffer)
    + volatility_weight * v
bid_k = tick_floor(r * (1 - (h + k*step)/10000))
ask_k = tick_ceil (r * (1 + (h + k*step)/10000))
```

Quotes must remain outside the opposite touch, notional and stock budgets
bound their levels, and `paper_fill/2` only applies to IDs present in the
current owned quote set. The model is **inventory-sensitive and deterministic**;
it is not a mathematical implementation of the full Avellaneda–Stoikov
stochastic control solution, a profitable strategy guarantee, or a continuous
elliptic-curve AMM.

## Where the elliptic curve is used

For a canonical event `e` and previous digest `d`, the SHA-256 audit digest is
`d' = SHA256(d || deterministic_term_binary(e))`. ECAI derives a P-256 scalar
`k = 1 + (SHA256({d,e}) mod (n-1))`, and the public curve point `K = [k]G`.
This maps repeated state/event inputs to repeatable P-256 points. `verify_audit`
replays the retained segment and confirms both SHA-256 digests and curve points.
This is a *non-hiding digest-to-point index*, not a Pedersen commitment or a
pairing proof. The elliptic group has no order relation suitable for expressing
a monetary bid or ask without a separate numerical model.

## Paper accounting and limitations

`equity = USDT + DAMAGE * mid`, `net paper P&L = equity - opening_equity`,
`drawdown = max historical peak-to-current percentage`. Explicit paper fills
charge configured maker fees and change both holdings and cash, so their P&L
feeds into the next mark and chart sample. No market trade is automatically
assumed to have filled an order. The BTC benchmark is a 100% buy-and-hold
hypothetical, not an executed position. Separate deposits/withdrawals after
opening equity are not currently supported (would require external-flow P&L
adjustments). DETS stores snapshots and recent events; history retention can be
configured. Auditing the retained suffix uses a checkpoint when older events
are pruned.

## Safety conditions

- Public Coinstore book must be nonempty, positive and uncrossed.
- Coinstore public API is TLS-verified; no API key required for reads.
- Feed age is checked; failed polls immediately withdraw paper quotes.
- Excessive price jumps, drawdown and optional price-feed divergence halt quotes.
- Inventory limits and maker-fee budget prevent overspending on simultaneous
  quote fills; manual fills must use a current quote ID and available funds.
- No live execution adapter exists; `mode => live` is rejected during startup.
- HTTP handler denies all requests unless the embedding router supplies an
  account-aware `authorize` callback.

## Future live-mode requirements

Confirm current symbol availability and permissions, contract/decimal rules,
fee tiers, and exchange minimums. Authenticate an actual Coinstore market-maker
account, maintain an ownership ledger by `clOrdId`, query/reconcile live orders
and balances on restart, never batch-cancel unowned orders, and implement
rate-limit/backoff/clock synchronization. Record realized executions/funding
rather than synthetic fills. Add idempotent order acknowledgment and timeout
handling, circuit breakers, kill switch reconciliation, exchange-specific
self-trade prevention, and independent audit checkpoints before connecting
private API calls.
