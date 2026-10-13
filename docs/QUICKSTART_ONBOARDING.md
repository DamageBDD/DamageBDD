# DamageBDD: URL -> Gherkin -> free status check -> report -> schedule

This feature is **opt-in**. It adds a standalone `/try` page and a tiny
HTTP GET status-check trial; it does not modify `/execute_feature/`, DAMAGE
accounting, wallet authentication, domain authorization or existing schedules.

## Feature flow

1. `GET /try`: enter a complete HTTPS URL (no query, fragment or userinfo).
2. `POST /api/quickstart/generate` with JSON `{"url":"https://example.com/"}`.
   Returns deterministic DamageBDD-compatible Gherkin, no external request.
3. `POST /api/quickstart/run` with the **same** JSON body and the
   HttpOnly session cookie issued by `/generate`. Executes exactly one bounded
   HTTPS GET **only** if the exact hostname/path is on the operator allowlist.
4. A time-limited `/try/report/<48-hex-character-id>` capability URL shows the
   expected/observed status and generated feature, with no response body.
5. `Schedule daily` posts the `.feature` directly to the existing authenticated
   `/schedules/daily/every/1/day` API. Existing balance checks and domain policy
   apply, and successful scheduling does **not** use free trial credits.

The trial is not a full `damage:execute_data/3` execution. It verifies
one read-only HTTP status observation and does not produce an IPFS hash or an
on-chain confirmation. Paid executions still use the existing DamageBDD engine.

## Configuration (`config/sys.config`, inside the `damage` application tuple)

The default is **disabled**. Merge with the existing `{damage, [...]}` entries:

```erlang
{quickstart_enabled, true},
{quickstart_state_dir, "/var/lib/damage/quickstart"},
{quickstart_cookie_secure, true},
{quickstart_trial_enabled, true},
{quickstart_trial_targets, [
    {"demo.your-company.com", ["/health"]}
]},
{quickstart_quota_secret, <<"REPLACE_WITH_RANDOM_32_OR_MORE_BYTES">>},
{quickstart_max_peer_per_hour, 5},
{quickstart_max_generations_per_peer_hour, 10},
{quickstart_max_inflight, 4}
```

Create a **real secret** (not the example text), keep it outside Git, and
protect the state directory. Enable the free run only after reviewing the
approved exact paths and the service's network egress rules. Do not add
customer-supplied domains to the allowlist without proving ownership and
reviewing the exact requested GET path. An allowlisted GET must be safe and
idempotent, with no private data in its URL or response headers.

**Important reverse-proxy limitation**: the basic trial quota keys on the
Cowboy TCP peer address, *not* untrusted `X-Forwarded-For`. When TLS terminates
at a reverse proxy, this may put all visitors in the same per-peer quota.
Before launching a public trial behind such a proxy, add a validated
trusted-proxy peer identity mechanism (or require accounts for trials), and
use shared distributed rate limits if nodes are load-balanced. The HTTP
interface deliberately does not implement a spoofable proxy-header shortcut.

For a local HTTP developer server you may set `{quickstart_cookie_secure, false}`;
never use that in production.

## Security boundaries

- Generation does not fetch, crawl, or execute the URL.
- Free execution requires an explicit exact target allowlist, an HttpOnly trial
  cookie, a configured HMAC quota secret and a per-peer limit; it is never
  exposed merely because someone can generate Gherkin.
- Only HTTPS/443, no credentials, queries, fragments, custom ports or redirects.
- DNS is resolved to IPv4, every A record is checked for non-public ranges,
  then Gun connects directly to the selected validated IP. HTTP Host and TLS
  SNI/certificate validation use the original hostname. No configured proxy.
- Only the HTTP status is observed. The GET response body is not consumed or
  saved. Timeouts apply to connection and response. The trial check is not a
  general HTTP scanner, security scanner or load-testing interface.
- DETS persists per-session one-use quotas, per-peer hourly quotas, generation limits and the
  reports; expired report and quota records are swept hourly.
- Reports contain sanitized target URL (without query parameters), generated
  feature, status and timing. Capability URLs are high-entropy and expire after
  24 hours. Treat links as bearer credentials. No third-party resources appear
  in the standalone report.
- The free trial does not issue an account, sign blockchain transactions, spend
  client tokens, and does not disable checks on scheduled/paid execution.

### Before accepting arbitrary customer-owned URL execution

This MVP **does not** provide automatic domain ownership verification or
cross-node globally limited trials. For production self-service testing at
arbitrary domains, integrate `damage_domains` ownership proof, safely scoped
per-target execution policy, trusted-proxy authentication, a shared quota store
and network-level egress restrictions. Keep the default free-run allowlist
empty until those controls are in place.

## Build and verify

```sh
rebar3 compile
rebar3 eunit --module=damage_quickstart_tests
node --check apps/damage/priv/static/js/quickstart.js
```

Try generation after enabling the feature:

```sh
curl -fsS -X POST http://127.0.0.1:4888/api/quickstart/generate \
  -H 'Content-Type: application/json' \
  -c /tmp/damage-quickstart.cookies \
  --data '{"url":"https://example.com/"}' | jq .

# Only when trial_enabled, allowlisted and quota_secret are configured:
curl -fsS -X POST http://127.0.0.1:4888/api/quickstart/run \
  -H 'Content-Type: application/json' \
  -b /tmp/damage-quickstart.cookies \
  --data '{"url":"https://example.com/"}' | jq .
```

For a developer HTTP listener, set `quickstart_cookie_secure=false` or
cookies will not be sent by browsers. The browser's `Schedule daily` button
requires an authenticated account/session and a supported schedule route.

## Planned follow-on

Add an authenticated customer-domain proof flow, preview runs using the actual
`damage:execute_data/3` engine with funded trial entitlements, and a direct
"save as project test" action. These are deliberately not implied by this
small, secure initial trial.
