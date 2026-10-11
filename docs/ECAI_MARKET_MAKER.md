# ECAI Market Maker — Coinstore DAMAGEUSDT / BTCUSDT

Additive, **paper-only** implementation for the DamageBDD Erlang/OTP application.
It uses Coinstore's public order-book/ticker endpoints and reuses the known
`price_feed:damage_to_sats/1` function as an optional cross-check. A read-only,
auth-gated dashboard plots **actual collected** DAMAGE/BTC prices and paper
performance. No historical prices or trades are fabricated.

**Status:** source package and EUnit tests provided, but compilation against the
current DamageBDD checkout and exchange connectivity have **not** been verified
in the creation environment. No current DamageBDD source archive was attached
to this request; this is an additive integration overlay, **not a rebase**.

## Files

- `docs/ECAI_MARKET_MAKER.md` — installation, configuration, operator commands, and risk boundaries.
- `docs/ECAI_MARKET_MAKER_ARCHITECTURE.md` — technical design, quote mathematics, and audit model.

- `apps/damage/src/ecai_mm_feed.erl` — verified-TLS public Coinstore book/tickers;
  diagnostic DamageBDD `price_feed` integration; injectable network adapter.
- `apps/damage/src/ecai_mm_curve.erl` — deterministic fee-aware,
  inventory-sensitive, volatility-aware quote ladders and P-256 curve indexes.
- `apps/damage/src/ecai_mm_ledger.erl` — funded, owned-order paper fills and
  USDT mark-to-market accounting.
- `apps/damage/src/ecai_mm.erl` — supervised paper worker, DETS restart state,
  stale-feed/risk kill switches, chained audit ledger.
- `apps/damage/src/ecai_mm_execution_plan.erl` — pure `POST_ONLY` Coinstore
  order intents and ownership-scoped reconciliation plan. **No I/O.**
- `apps/damage/src/ecai_mm_http.erl` — Cowboy read-only JSON and static UI.
  Defaults to *deny-all* until integrated with the existing DamageBDD auth flow.
- `apps/damage/priv/ui/ecai-market-maker/` — dependency-free charts and tables.
- `apps/damage/test/ecai_mm_*_tests.erl` — EUnit tests (synthetic fixtures only).

## Integrate, without breaking the existing trading path

1. Unpack in the top of a clean DamageBDD worktree. **Do not run the old
   `damage_mm` strategy simultaneously on the same Coinstore symbol and API
   account.** The older code can cancel unrelated active orders and disable TLS
   certificate verification. The new worker does not call it.
2. Ensure `crypto`, `public_key`, `ssl`, `inets`, and `jsx` are available to the
   DamageBDD application. The source is in `apps/damage/src` and assumes the
   existing dependency on Cowboy for API routing.
3. Provide the worker's config under DamageBDD's application env. For example,
   in `config/sys.config` (adapt existing config structure; do not duplicate the
   `damage` application entry):

   ```erlang
   {ecai_market_maker, #{
       mode => paper,
       auto_poll => true,
       poll_interval_ms => 10000,
       state_dir => "/var/lib/damage/ecai-mm",
       paper_balances => #{damage => 20000.0, usdt => 500.0},
       tick_size => 0.00000001,
       lot_size => 1.0,
       min_qty => 100.0,
       min_notional => 5.0,
       maker_fee_bps => 10.0,
       max_side_notional => 150.0,
       max_order_notional => 35.0,
       max_price_jump_pct => 25.0,
       max_drawdown_pct => 10.0,
       max_feed_age_ms => 20000,
       max_events => 5000
   }}
   ```

   These balances are **fictional PAPER capital**, only for a test run. The
   numeric tick/lot/minimums/fees above are examples, **not confirmed Coinstore
   DAMAGEUSDT rules**. Retrieve and validate the current instrument metadata
   (`POST /v2/public/config/spot/symbols`) before production. Keep `mode => paper`.
   If balances are omitted, they default to zero and no ladder is funded.

4. Start the worker after `price_feed` is started. The existing `damage_sup`
   `Core` children list can include:

   ```erlang
   #{id => ecai_mm,
     start => {ecai_mm, start_link, []},
     restart => permanent,
     shutdown => 10000,
     type => worker,
     modules => [ecai_mm]}
   ```

   This is **a sample insertion**, not an already-applied modification to the
   unseen current `damage_sup.erl`.

5. Wire only authenticated Cowboy routes. Supply a **real authorization function
   from the existing DamageBDD session/auth flow**. We deliberately do not
   guess the names or contracts of current auth modules:

   ```erlang
   %% Replace ExistingDamageSessionCheck with a real fun(Req)->boolean()
   %% from the currently deployed DamageBDD auth layer.
   AuthenticatedOptions = #{authorize => ExistingDamageSessionCheck},
   Routes = [
     {"/api/ecai/mm/:resource", ecai_mm_http, AuthenticatedOptions},
     {"/ecai/market-maker", ecai_mm_http,
        AuthenticatedOptions#{resource => dashboard}},
     {"/ecai/market-maker/:asset", ecai_mm_http,
        AuthenticatedOptions#{resource => asset}}
   ].
   ```

   On restart, outstanding paper quote IDs are invalidated until the first fresh
feed poll; only the previous accounting history survives. The handler returns
HTTP 403 if no `authorize` callback is configured.
   Integrate with the ECAI dashboard menu through a link to
   `/ecai/market-maker`, guarded by the same user permissions. **Do not expose
   `/api/ecai/mm/*` or the UI unauthenticated**; portfolio and order data is
   account-sensitive even in paper mode.

6. Build and run EUnit in the real checkout:

   ```sh
   rebar3 compile
   rebar3 eunit
   ```

## Operator functions (Erlang shell)

```erlang
ecai_mm:status().          %% feed freshness, quotes, risk halt, P&L, audit tip
ecai_mm:quotes().          %% active paper ladder, IDs and sizes
ecai_mm:history(300).     %% latest 300 chained samples/events
ecai_mm:verify_audit().    %% ok | {error, Detail}
ecai_mm:pause().           %% stop quote generation; persisted
ecai_mm:resume().          %% refuse resume if drawdown threshold breached

%% A paper fill uses a current quote ID; it cannot fill other accounts' orders.
%% This is a manual/synthetic paper fill, not an actual Coinstore execution:
[Q|_] = ecai_mm:quotes().
ecai_mm:paper_fill(maps:get(client_id,Q), 10.0).
```

If running outside the DamageBDD supervisor for a smoke test:

```erlang
application:ensure_all_started(crypto).
{ok, _} = ecai_mm:start_link(#{mode => paper, auto_poll => false,
                               state_dir => "/tmp/ecai-mm-smoke",
                               paper_balances => #{damage => 10000.0, usdt => 250.0}}).
%% Synthetic testing input only; never present this as Coinstore data.
ecai_mm:ingest(#{bid => 0.0099, ask => 0.0101, btc_usdt => 95000.0}).
ecai_mm:status().
ecai_mm:verify_audit().
```

## JSON APIs, after auth

- `GET /api/ecai/mm/status` — mark, balances, quoted levels, drawdown, P&L,
  fees, feed age, audit digest/point. Data is private to the operator.
- `GET /api/ecai/mm/history?limit=1000` — persisted market/P&L observations.
- `GET /api/ecai/mm/quotes` — active paper quotes.

The dashboard compares DAMAGEUSDT and BTCUSDT using indices initialized to
100 at the first successfully persisted sample. It compares paper equity to a
**hypothetical 100%-BTC benchmark starting with the same USDT equity**. Actual
returns depend on inventory and paper fills; the benchmark is not a hedging
position. Estimated portfolio P&L is NOT realized income.

## Model and integrity boundaries

The reservation price offsets the midpoint as inventory shifts away from a
configurable target. Bid/ask ladders expand with an EWMA of observed midpoint
log returns and impose a maker-fee floor. Quotes are quantized to the configured
price tick and lot size, constrained to available funds and guarded against
crossing the public opposite touch. The quote generator is deterministic given
its explicit inputs.

ECAI P-256 points map canonical state/event hashes to curve group points via
`H(state) mod n * G`. They index states and support equality/integrity checks;
they **do not** by themselves prove that Coinstore's data is genuine, hide the
input, provide price discovery, or predict returns. The engine maintains a
SHA-256 chained event log and exposes `verify_audit/0`; exporting the tip to a
separate trusted service is needed to detect replacement of the local ledger.

The prototype uses IEEE-754 arithmetic. A **live** order gateway additionally
requires decimal/integer amount accounting, instrument metadata and account
fee validation, authenticated inventory queries, per-order idempotency,
owned-order-only cancel/reconcile on restart, rate limit handling, precision
checks, post-only rejection handling, and trade/fee reconciliation. The provided
execution planner constructs post-only intents but **never submits them**.

There is no exchange order credential, capital transfer, automatic inferred
fill, wash trading, price support action, or market-manipulation routine in
this package. Paper fills require an explicit operator/replay event; consequently
spread-capture stats remain untested until fills are supplied.

A persisted paper balance overrides subsequent changes to `paper_balances` in
config; start a fresh state directory for a separate trial, rather than silently
rewriting accounting history.

## Sources

- Coinstore API: https://coinstore-openapi.github.io/en/index.html
- Existing DamageBDD `price_feed:damage_to_sats/1` usage in `damage_http.erl`.
- Prior DamageBDD `damage_mm` source reviewed from available project history;
  its outdated private-active-orders book reader was not copied.
