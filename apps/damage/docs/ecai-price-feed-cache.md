# ECAI price-feed cache and historical population

This extension adds a durable Coinstore price archive to the existing ECAI
paper market maker. It does not change the shared `price_feed.erl` conversion
service, paper starting balances, exchange credentials, or live-execution policy.

## Install and populate

Apply this incremental patch after the node-settings patch, its validation-test
correction, and the Coinstore TLS hostname correction. Compile and test, then
restart the node once to install the new `damage_sup` child and HTTP routes.
The application must be able to write to its existing state directory.

In **Settings → ECAI → Marketplace & rewards**, enable the paper market maker
and leave **Automatically populate price history** enabled. Automatic backfill
starts asynchronously; startup and HTTP reads do not wait for exchange requests.
The default request set is DAMAGEUSDT and BTCUSDT, each with hourly (`60min`)
and daily (`1day`) candles. Existing paper funds are not required to build charts.

To explicitly populate the archive from the running Erlang console:

```erlang
%% Enqueue the default two symbols and two periods; returns before HTTP completes.
ecai_mm_price_cache:backfill().

%% Request the maximum documented REST window for both hourly series.
%% A larger request is not discarded if a smaller request is already in flight.
ecai_mm_price_cache:backfill(#{period => <<"60min">>, size => 2000}).

%% Inspect progress, last errors and the oldest/newest timestamp in each series.
ecai_mm_price_cache:status().

%% Read aligned DAMAGE/BTC chart points (cached reads only).
ecai_mm_price_cache:history(<<"60min">>, 2000).

%% Read one raw OHLCV series, including source and retrieval timestamps.
ecai_mm_price_cache:candles(<<"DAMAGEUSDT">>, <<"60min">>, 2000).
```

Explicit `backfill/1` also accepts `symbol`, for example:

```erlang
ecai_mm_price_cache:backfill(#{symbol => <<"BTCUSDT">>, period => <<"1day">>, size => 2000}).
```

Manual requests work with the paper engine disabled. They do not enable it.
Disabling automatic backfill cancels automatic work, not explicitly requested
manual work. A request is complete when its job leaves `status().jobs`; inspect
series `last_error`, `last_batch_count`, and timestamp coverage as well. A completed
or empty response does not guarantee that the exchange has the requested history.

## Node Settings

The existing settings endpoint and node-admin permissions are reused. Four new
hot-applied controls are added alongside the existing 16 paper-engine controls:

| Key | Default | Allowed range |
| --- | --- | --- |
| `market_maker_price_cache_ttl_ms` | 1000 | 0–2000 ms |
| `market_maker_history_auto_backfill` | true | Boolean |
| `market_maker_history_bars` | 720 | 1–2000 bars per request |
| `market_maker_history_refresh_ms` | 300000 | 60000–86400000 ms |

Zero TTL disables reuse of completed live requests, but concurrent requests are
still coalesced. Automatic refresh reads the current validated settings on each
scheduler tick. Changed request sizes apply to queued/upcoming windows; they do
not erase older retained candles. Invalid settings are rejected rather than
silently coerced to new defaults.

Private deployment options may be supplied under the **damage** application:

```erlang
{ecai_mm_price_cache, #{
    %% Optional; normally derived from damage_config:state_dir().
    state_dir => "/var/lib/damage/ecai-mm-price-cache",
    history_periods => [<<"60min">>, <<"1day">>],
    retention_bars => 10000
}}
```

Insert that entry into the existing application's configuration, not as another
standalone application definition. Private startup options require a restart.
`retention_bars` accepts 2000–10000 and is a per-symbol/per-period limit.
`history_periods` accepts the nine documented REST periods below; the dashboard
selector presents the standard hourly and daily views. Changing the directory
selects a different cache; it does not migrate existing data.

## Storage and recovery

`ecai_mm_price_cache` is a supervised gen_server independent of `ecai_mm`.
It stores `prices.dets` under:

```erlang
filename:join(damage_config:state_dir(), "ecai-mm-price-cache").
```

The cache retains closed OHLCV candles, per-series fetch metadata, pending jobs,
retry deadlines and the last successful live snapshot. Series updates are synced
before a completed job is removed and synced. Interrupted jobs can repeat their
last request after restart; merging by symbol, period and timestamp is idempotent.
Revised candles replace overlapping rows, while older cached rows remain until
retention pruning. No entire tick-by-tick exchange archive is implied.

There is at most one live fetch and one historical fetch in flight. Concurrent
live callers share a request (up to 64 waiters). Historical requests are paced at
least one second apart, with a bounded queue for the two symbols and nine periods.
Request errors are retried with exponential backoff, up to five failed attempts
per queued job; automatic refresh can try again later. Recent live failures have
a five-second cooldown and never return an old success. Both paths use bounded
worker deadlines. An incomplete job remains recoverable after a process restart.

A restored live snapshot is **display-only**. A new successful network request is
required before this process can reuse a live cache entry. No cache read changes
the original `fetched_ms`. Live receipt age starts when the combined depth/ticker
request begins, conservatively including request latency.

DETS is local storage, not exchange authentication or a remotely anchored audit.
Keep its filesystem access restricted to the node operator and include the state
directory in normal operational backups. Storage write failures are not reported
as successful cache writes. This cache is separate from the existing paper ledger.

## Historical-data contract and limits

The adapter implements the official Coinstore REST request:

```text
GET https://api.coinstore.com/api/v1/market/kline/{symbol}?period=60min&size=720
```

Supported symbols are `DAMAGEUSDT` and `BTCUSDT`. Supported periods are `1min`,
`5min`, `15min`, `30min`, `60min`, `4hour`, `12hour`, `1day`, and `1week`.
Coinstore documents `size` from 1 to 2000 and timestamps in seconds. The adapter
converts timestamps to milliseconds, verifies the response symbol and interval,
validates OHLC consistency and non-negative volume, rejects malformed/conflicting
rows, and excludes candles still open at request start (with a five-second close
guard). Numeric bounds prevent non-finite chart ratios.

**The documented REST endpoint has no start/end pagination cursor.** Backfill
fetches recent windows and extends the local archive over time. It cannot recover
arbitrary old periods outside the returned window, nor create bars before a
listing. The separately documented WebSocket historical interface is not part of
this patch. Gaps remain visible; there is no synthetic fill, forward-fill, or
mixing of today's BTC ticker with an older DAMAGE close.

Provider reference, reviewed for this implementation:
`https://coinstore-openapi.github.io/en/#get-k-line`

HTTP retains `verify_peer`, CA validation, explicit SNI and the previous HTTPS
wildcard hostname matcher. No redirects, certificate bypass, credential capture,
or fallback to a different exchange is introduced. Successful streaming bodies
are capped at 4 MiB and deadline-limited. A failing live feed can coexist with a
readable historical archive; the archive is not a workaround for failed TLS.

## Dashboard and read API

Open `/ecai/market-maker` as an authenticated node administrator. The market chart
uses aligned closed candles, with a real time axis, period selector, source label,
and visible gaps. Without candles it uses clearly labelled observed engine ticks.
The P&L chart continues to use only the actual paper engine's recorded timeline.
Historical price data never creates earlier equity, fills, profits or quote IDs.

New **GET-only, node-admin-gated** routes:

```text
/api/ecai/mm/price-cache
/api/ecai/mm/prices?period=60min&limit=2000
/api/ecai/mm/prices?symbol=DAMAGEUSDT&period=60min&limit=2000
```

The first reports cache state. The second returns paired chart rows and gaps. The
third returns normalized single-symbol candles. Reads work while the paper engine
is off and never enqueue network work. Limits are 1–2000; invalid symbol/period/
limit values return 400. The existing `/api/ecai/mm/history` still returns the
paper engine's audit/performance timeline, not this historical price archive.

The engine now polls asynchronously and remains responsive to status/pause
requests during slow feed requests. Re-reading a cached live receipt cannot add
another tick, update volatility twice, or replenish a partially filled quote.
Tagged historical input is rejected by the ingestion path. Stale or paused quotes
are not displayed as active in the dashboard.

## Verification and tests

Run the full repository checks:

```bash
rebar3 compile
rebar3 eunit --module=ecai_mm_candles_tests,ecai_mm_price_cache_tests,ecai_mm_feed_tests,ecai_mm_tests,ecai_mm_settings_tests,ecai_mm_control_tests,damage_settings_schema_tests,damage_settings_tests
python -m unittest discover -s apps/damage/test/scripts -p test_ecai_mm_price_cache_browser.py -v
python -m unittest discover -s apps/damage/test/scripts -p test_node_settings_feature_browser.py -v
```

For the isolated, offline Erlang suite without booting the full application:

```bash
bash apps/damage/test/scripts/test_ecai_price_cache.sh
```

The helper compiles the selected modules with `-DTEST -Werror` in a temporary
output directory and runs EUnit against injected provider fixtures. It requires
an installed Erlang compiler and EUnit/crypto/public_key/inets packages. It does
not download dependencies or contact Coinstore.

New EUnit cases cover parser bounds, closed-candle filtering, deduplication,
retention, shared timestamps, cache TTL/reuse, single-flight, offline reads,
restart recovery, durable pending work, backoff, request upgrades, auto-disable,
and the historical/live and quote-reuse safety boundaries. Browser fixtures cover
six chart/status contracts; the eight existing Settings browser contracts remain
part of regression checking. Browser tests use synthetic in-memory responses and
do not constitute a backend authorization or exchange integration test.

At preparation time: 14 browser tests passed; JavaScript and shell syntax and
patch-application checks passed. **Erlang compilation/EUnit, authenticated Cowboy
integration, and a live Coinstore handshake/response remain unverified in the
build environment.** Run the above checks on the development node before rollout.
