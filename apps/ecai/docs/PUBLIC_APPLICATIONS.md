# Public dashboard applications

Applications now contains both **Supply chain · Recovery Lab** and **Orbital verification**.
Direct views remain `/dashboard#supply-chain` and `/dashboard#orbital`.

Orbital verification remains a local browser demonstrator: no account, wallet, API
request or server-side compute job is needed. The Recovery Lab now works without
sign-in through separate public API routes and an isolated temporary workspace.

## Install the follow-up

This patch is against `latest-ecai-with-recovery-lab.tar.gz` from the previous change.
It is not the initial Recovery Lab patch. From the DamageBDD repository root:

```sh
PATCH="$HOME/Downloads/ecai-public-applications.patch"
git apply --check "$PATCH" && git apply "$PATCH"
rebar3 compile
apps/ecai/test/run_supply_chain_tests.sh
```

Restart the existing release so the new guest module, service state and routes are
loaded. Do not just hot-load the HTTP module; the service now owns new private ETS
session tables. The console import and shell asset URL have been cache-busted.

The companion `latest-ecai-public-applications.tar.gz` is an alternative updated ECAI
application archive, not a complete DamageBDD umbrella and not an additional patch.
Review it before replacing any newer local edits.

For a TLS-terminating reverse proxy, set `{supply_chain_public_origin,
<<"https://your-dashboard-host">>}` in the existing `ecai` section. Use the exact
external origin, including nondefault port if any, without a trailing slash. The
handler deliberately does not trust arbitrary forwarding headers. See
`priv/config/supply_chain.example.config` and `docs/SUPPLY_CHAIN_RECOVERY_LAB.md`.

## Behaviour

Guests and wallet-only visitors can load scenarios, disrupt the network, retrieve
and repair plans, approve simulated plans, benchmark and export their own evidence.
No operation dispatches vehicles, spends money or accesses private account memory.

Guest state is server-memory-only and expires after 30 minutes idle or restart.
A browser's tabs share its demo cookie; separate cookie jars get separate workspaces.
Signing in switches to the existing durable account workspace, without migrating
guest cases. Signing out returns to the temporary demo, while old account requests
are aborted and late responses cannot refill the panel.

The public routes use `/ecai/supply-chain/public` and the same action suffixes as the
existing private API. Private routes still enforce managed-account authentication.
Public routes require a dedicated request header, reject cross-origin browser calls,
and use an HttpOnly, SameSite=Strict, path-scoped random demo cookie. HTTPS origins
also set Secure. Cookie creation happens only on GET of the public root. An expired
POST receives 410; the UI refreshes without automatically replaying it.

Defaults bound anonymous use to 32 sessions, one guest worker, 64 cases per session
and per-session/per-peer token buckets. Account workspace slots remain separate.
The existing total worker limit, input limits, body-size limit, revisions and full
plan revalidation remain in force. These limits do not replace edge rate limiting.

Set `{supply_chain_public_enabled, false}` to disable guest APIs without disabling
managed workspaces or the local orbital demonstrator.

## Checks

Executed here: 11 source/checksum Python tests, 6 Recovery Lab JavaScript tests,
8 orbital tests, JavaScript syntax checks and the production Recovery Lab browser
flow with explicitly mocked API responses. Browser coverage includes guests,
wallet-only mode, sign-in isolation, logout, late responses, stale proposals, expiry,
rate-limit messages and mobile overflow. No fake timings are added to production.

Erlang/OTP and rebar3 were unavailable here. Erlang compilation, EUnit, live Cowboy
cookie/Origin handling and full-umbrella auth integration have **not** been run.
The standalone runner includes the added public-session EUnit suite for your node.

The existing broad `test_console_contract.py` also needs the omitted Damage app's
shared auth/agent templates; its route and navigation expectations were updated,
but the full fixture could not run from this ECAI-only upload.

The public-origin construction follows the official Cowboy `cowboy_req:uri/2`
serialized-origin example, converting its iodata result to a binary before comparison:
https://ninenines.eu/docs/en/cowboy/2.10/manual/cowboy_req.uri/
