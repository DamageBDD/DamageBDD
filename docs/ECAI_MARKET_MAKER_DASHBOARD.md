# ECAI Market Maker — Dashboard and Live Paper Configuration

The ECAI control plane has a **Market Maker** item in its primary navigation
(`/dashboard#market-maker`). The page is split into four operator subsections:

| Subsection | Function |
|---|---|
| Live market | DAMAGE/USDT + BTC/USDT observations, indexed price chart, spread, EWMA volatility, fresh/stale state, bid/ask ladders |
| Strategy & risk | Runtime, bounded quote parameters; guarded pause/resume and fetch-now commands; persisted configuration revision |
| Performance | USDT paper equity, mark-to-market P&L, drawdown, fees, turnover, fills, hypothetical 100%-BTC benchmark |
| State & audit | SHA-256 event digest, P-256 state point, retained event history, explicit verification request |

The control plane polls status approximately every four seconds while its tab
is visible; history refreshes about every 11 seconds. The market-maker worker
itself polls Coinstore at `poll_interval_ms` (default 10000ms). This is **polling,
not an exchange push stream**. On navigation away, refresh timers stop. Charts
start at the earliest actual persisted observations returned by the worker:
**there is no invented history and no assumption that quotes were filled**.

## Deployment

1. Install the market maker from `apps/damage/src/ecai_mm*.erl`, with the
   previously provided modules `ecai_mm`, `ecai_mm_curve`, `ecai_mm_feed`,
   `ecai_mm_ledger`, and their related tests. Add `ecai_mm_config.erl` and the
   updated `ecai_mm.erl` from this change. **Do not apply the updated worker over
   an independently modified version without checking the diff.**
2. Start `ecai_mm` under `damage_sup` **after `price_feed`**. Example OTP child:

   ```erlang
   #{id => ecai_mm,
     start => {ecai_mm, start_link, []},
     restart => permanent, shutdown => 10000,
     type => worker, modules => [ecai_mm]}
   ```

   The dashboard does not auto-start market-making or create paper balances.
   See `docs/ECAI_MARKET_MAKER.md` for explicit `ecai_market_maker` paper
   balances, state directory, feed, and risk settings.
3. Install the updated `apps/ecai` templates, JS, CSS and `ecai_mm_dashboard_http`
   module. Its `trails/0` is added to `ecai_app:get_trails/0`. Restart the ECAI
   listener or explicitly reload its trails according to the deployment process.
4. Enable the operator feature in the `ecai` application configuration only
   after confirming the DamageBDD `node_admins` allowlist. For example:

   ```erlang
   {ecai, [
       {market_maker_admin_enabled, true},
       {market_maker_accounts, []}
   ]}
   ```

   This is a **fragment** of the existing `ecai` config; do not add a second
   `{ecai, ...}` application entry. Empty `market_maker_accounts` means all
   authenticated *DamageBDD node admins* may access it. Set a nonempty list to
   further restrict those administrators. Default is disabled. Wallet-only
   sessions are rejected even if their public key appears in `node_admins`.
5. Log in with the managed DamageBDD admin account and navigate to
   `/dashboard#market-maker`. If the engine has not been started, the API
   returns 503 and the UI correctly reports it as unavailable.

## Runtime REST API

The ECAI listener serves the following routes, separate from the older
DamageBDD `/api/ecai/mm/*` read-only prototype. All requests are restricted to
managed, allowlisted node admins and return no-store JSON. POST operations
**require an explicit valid bearer token**; cookies alone cannot authorize
mutations. The dashboard obtains this token through existing DamageBDD browser
session handling and never displays it or stores Coinstore exchange keys.

- `GET /ecai/mm/status` — current feed, freshness, active paper quotes, risk
  state, ledger performance, config revision and audit commitment.
- `GET /ecai/mm/quotes` — paper quote ladder.
- `GET /ecai/mm/history?limit=800` — bounded persisted event timeline.
- `GET /ecai/mm/config` — editable safe values, revision and `execution_enabled=false`.
- `POST /ecai/mm/config` — `{"expected_revision":0,"changes":{"levels":6}}`.
  Writes are bounded, persisted, and invalidate existing paper quotes until a
  fresh accepted feed cycle. Stale revisions produce HTTP 409.
- `POST /ecai/mm/control` — `{"action":"pause"}` or `"resume"` or `"poll"`.
- `GET /ecai/mm/audit` — verify the retained local hash/curve commitment chain.

Only allowlisted numeric strategy/risk fields are editable. API requests
containing unknown properties (`mode`, `paper_balances`, API credentials,
wallets, exchange order endpoints) are rejected. Edits cannot enable live
trading, execute exchange orders or override `paper_fill/2`'s explicit fill
requirement. `poll_interval_ms` must not exceed `max_feed_age_ms`.

**State lifetime:** Editable config is stored in the existing `ecai_mm` DETS
store and restored across restarts. Active quotes are invalidated at restart
until fresh market data arrives. Opening paper capital cannot be modified
through this dashboard: use a separate state directory for a new trial.

## Test and verification

```sh
rebar3 compile
rebar3 eunit
python3 -m unittest apps/ecai/test/test_mm_dashboard_contract.py
python3 apps/ecai/test/test_mm_dashboard_browser.py
```

The standalone browser test uses explicit **synthetic fixture inputs** only,
for testing interface behavior. No price data from test fixtures is shipped as
live observations. Both applications must be present in the real worktree for
umbrella integration tests. Running the frontend tests alone cannot establish
that the current DamageBDD `price_feed`, authentication service, or Coinstore
connectivity is operational.
