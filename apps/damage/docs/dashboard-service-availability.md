# Dashboard service availability

This update fixes unrelated background requests and recovery behavior around
the three reported HTTP 503 responses. A 503 means the server responded but the
requested service was unavailable; it does not by itself identify a network,
authentication or storage fault.

## What changes

| Request | Updated behavior |
| --- | --- |
| `GET /api/node/tax/settings` | First read waits until the tax panel opens. Tax setup remains accessible while reporting is disabled. Failed reads and uncertain saves keep fields read-only until Reload succeeds. |
| `GET /ai/bdd/routing` | Routing and the step catalog wait until the execution panel opens. Failed routing reads disable route changes and explain how to retry. No route is inferred from a failed request. |
| `GET /api/billing/session` | A strict server-rendered disabled flag skips the session request. Enabled or older pages still use the real session API. A separate availability card distinguishes service failures from access failures and provides retry. |

Panel changes do not create repeated retry loops. Account changes clear cached
privileged state and invalidate responses belonging to the previous session.
Billing's generic availability card may be navigated to before invoice access
is granted; private invoice controls still require a successful session response.
No service is enabled automatically and no API authorization rule is changed.

## Deploy and verify

1. Compile and deploy the changed dashboard Erlang module, billing template and
   JavaScript assets using the normal release process. Refresh the browser's
   cached assets after deployment.
2. Open the bunker panel directly. Hidden tax and execution panels should make
   no settings, catalog or routing requests. Explicitly disabled billing should
   make no billing session request. Enabled billing can still check its session.
3. Open Tax reporting. Its settings load even when tax reporting is disabled.
   On a failed read, confirm the message names the unavailable settings service,
   fields cannot be saved, and Reload remains available.
4. Open the execution workspace. Catalog and routing each load once. If routing
   returns 503, it remains unavailable and route controls are disabled; use
   Refresh after the server issue is resolved. Feature editing remains available.
5. Open Billing. Disabled nodes show the configuration status. On an enabled
   node, a successful session reveals invoice controls; 401/403 retain the
   access boundary, while 503 shows service guidance and a retry button.
6. Switch accounts while requests are pending. Responses from the old session
   must not restore its fields, routing preferences or invoice display.

## If a visible feature still returns 503

The frontend cannot repair a missing settings snapshot, unavailable operational
identity, unreadable store or stopped backend worker. Keep the service failure
visible and resolve the cause before retrying.

**Tax settings:** the available handler returns `tax_settings_unavailable`
when its restricted projection cannot read the node settings service. Tax
enablement is not a prerequisite for this endpoint. In the node's trusted Erlang
console, inspect:

```erlang
whereis(damage_settings).
damage_settings:status().
```

Review settings startup/reload logs and the reported configuration error.
Correct the approved base/overlay configuration or service access, then use
`damage_settings:reload().` and Reload settings. Keep the detailed diagnostic
output in operator records; the tax endpoint intentionally omits unrelated
settings and private filesystem details.

**Billing:** the available service returns unavailable when enterprise billing
is disabled, the operational node identity is unusable, invoice storage cannot
load/save, or the worker cannot complete the request. Read-only checks in the
trusted Erlang console are:

```erlang
proplists:get_value(enabled,
    application:get_env(damage, enterprise_invoices, []), false).
whereis(damage_enterprise_invoices).
secrets:ready().
```

If billing is intentionally disabled, the availability message is the expected
result. Otherwise review worker/storage logs and the approved operational
identity setup, then retry. `secrets:ready() = false` is broader than a locked
password: it can also mean the keypair is missing or unusable. Bunker signing
identity and AWS custody remain separate from these billing checks.

**BDD routing:** inspect the failed request's JSON response in Network and the
corresponding node logs. Check the deployed routing/settings service and the
approved BDD provider-role configuration. The deployed routing frontend was
recovered for this patch; its newer backend handler is absent from the supplied
application archive, so this update makes no unsupported backend change. Do not
replace a failed routing response with a guessed default or success status.

## Validation boundaries

The patch is based on the available application snapshot with the delivered
bunker changes. Billing and tax JavaScript were byte-compared with the deployed
public assets; current deployed composer and routing assets form those two
files' patch baseline. Browser regression tests use local mocked API responses,
including real HTTP 503 responses, delayed replies and account switches.

The changed Erlang dashboard module is compiled with warnings treated as errors.
The complete umbrella release and live backend availability still require the
normal deployment checks. No production session, invoice operation, settings
save, service restart or signing operation was performed during validation.
