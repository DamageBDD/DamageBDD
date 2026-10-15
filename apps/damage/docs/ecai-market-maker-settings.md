# ECAI paper market maker: node Settings

In the authenticated node-admin Settings page open **ECAI → Marketplace & rewards**.
Enable **ECAI paper market maker**, optionally open **Advanced paper strategy & risk**,
and save. The settings are stored as a versioned, typed ECAI configuration in the
node's XDG `damage.config` file, not in the current account or browser storage.
The supervised controller reconciles the worker immediately and periodically;
reload the page to see its actual state. Disable to stop the worker. During a
stop, simulated quote IDs cease to be active; on restart, saved audit events and
fills are preserved but previous quotes do not accept fills without a fresh feed.

All 15 strategy/risk fields are validated by `ecai_mm_config:validate/2`,
including cross-field inventory, exposure and feed-age invariants. Invalid saves
are rejected before touching the overlay. API writes use the existing
`POST /api/admin/settings/ecai` endpoint with a node-admin session, an action
header, a same-origin policy and an optimistic config version. Names-only
protected fields such as `market_maker_accounts`, `market_maker_admin_enabled`,
and `marketplace_enabled` remain non-editable.

`market_maker_enabled` **does not** enable `marketplace_enabled` or live exchange
orders. This worker has no exchange execution adapter and only runs in `paper`
mode. The read-only dashboard is available at `/ecai/market-maker`, and the
JSON endpoints are `/api/ecai/mm/status`, `/quotes`, and `/history`. All require
node-admin authentication; unavailable workers return HTTP 503, not fabricated
market data. There are no configuration-write or order endpoints on this route.

The existing operator-managed `{damage, [{ecai_market_maker, #{...}}]}` map can
still supply private `state_dir`, simulated starting `paper_balances` and
`auto_poll`. These options are intentionally NOT exposed via the Settings UI.
When `state_dir` is absent, the controller preserves an existing legacy
`/var/lib/damage/ecai-mm` ledger; otherwise it uses
`filename:join(damage_config:state_dir(), "ecai-mm")` (typically the XDG state
root). Ensure the node has write permission. Initial paper balances default to
zero and yield no funded simulated quotes until explicitly configured by the
trusted operator. The Settings values take precedence over any previous
DETS-only *strategy* overrides for a controller-managed worker.

## Erlang diagnostics

```erlang
ecai_mm_control:status().
ecai_mm_control:sync().
ecai_mm:config().
ecai_mm:verify_audit().
```

Never turn this on for live funds or treat paper P&L as realized exchange profit.
The existing elliptic-curve commitments cover local deterministic state, not
exchange-data authenticity or execution proof.

## Tests

```sh
rebar3 compile
rebar3 eunit --module=ecai_mm_settings_tests,ecai_mm_control_tests,damage_settings_schema_tests,damage_settings_tests
python -m unittest discover -s apps/damage/test/scripts -p test_node_settings_feature_browser.py -v
```
