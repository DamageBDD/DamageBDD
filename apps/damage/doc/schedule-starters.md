# Dashboard starter schedules

The Schedules workspace now offers nine opt-in templates. Choose **Use template**,
enter a public/non-secret endpoint, confirm ownership/permission, then **Review
schedule → Calculate budget → Enable & lock budget**. Merely loading the dashboard,
choosing a template, or calculating its budget does not send monitoring traffic.
Starter schedules use a seven-day window; the user can change it before activation.

| Template | Default cadence | What is verified |
| --- | --- | --- |
| HTTP uptime & latency | Every 15 minutes | GET status and elapsed-time threshold |
| Page content canary | Hourly | HTTP 200, public text and response time |
| TLS certificate expiry | Daily, 09:00 UTC | Trusted chain, hostname and minimum remaining validity |
| Web security headers | Daily, 09:00 UTC | HSTS, nosniff, CSP and strict frame protection |
| Self-hosted node exposure | Daily, 09:00 UTC | Git HEAD, .env availability, Kubo RPC and Go pprof paths |
| Docker API exposure | Daily, 09:00 UTC | Anonymous version response on one explicitly selected listener |
| IPFS content availability | Hourly | A nonempty bounded CID gateway range response |
| Nostr relay information | Every 15 minutes | HTTP NIP-11 document with a supported_nips array |
| Protected endpoint guard | Hourly | Anonymous requests receive HTTP 401 or 403 |

There is no second scheduler or new escrow contract. Templates produce ordinary
features and use existing Schedule V2 preview, creation, wallet-signing, run,
pause, resume, cancel, history and budget accounting paths. Nothing is created
until the final enable action. Wallet redirects are not reported as completed
activation before confirmation.

## Target authorization

The permission checkbox records an explicit user acknowledgement; it is **not**
the network authorization boundary. Every live check requires this account's
exact-host DNS proof through `damage_domains:lookup_domain/2`, or an exact
operator-approved owner/origin tuple. The monitor does not use the ordinary HTTP
step's developer-domain, `.local`, `.lan` or localhost authorization bypasses.
Use the existing Domains settings to obtain a token and publish the account's
`damagebdd_token=<token>` TXT record on the exact target hostname. Existing token
expiry and revocation still apply and are checked again on each execution.

Operator grants are optional. Merge these tuples into the existing `damage`
application entry in `sys.config` (replace the example account/targets):

```erlang
{damage, [
    %% Exact owner and origin. DNS changes are checked again for every run.
    %% Only globally routable addresses are accepted by this grant.
    {monitor_targets, [
        {<<"ak_REPLACE_WITH_OWNER">>, <<"https://node.example.com">>},
        {<<"ak_REPLACE_WITH_OWNER">>, <<"https://node.example.com:2376">>}
    ]},

    %% Private monitoring is OFF by default. These grants require literal IP
    %% origins, not user-controlled DNS names, to avoid rebinding within a LAN.
    %% Loopback means the DAMAGE RUNNER's host, not the dashboard browser.
    {monitor_private_targets, [
        {<<"ak_REPLACE_WITH_OWNER">>, <<"http://127.0.0.1:8080">>},
        {<<"ak_REPLACE_WITH_OWNER">>, <<"http://192.168.1.50:2375">>}
    ]}
]}.
```

The origin fixes the scheme, host and port; paths are not prefix authorization
rules. Do not grant arbitrary accounts access to a runner's local services.
Link-local/metadata, unspecified, multicast and reserved ranges remain blocked.
Private overrides cover only explicit loopback/RFC1918/ULA IP targets and exclude
known metadata addresses. DNS targets resolving to blocked addresses are rejected.
The transport connects to a checked numeric address with the original Host and
TLS identity, never to a hostname resolved a second time. No redirects, credentials,
cookies or account headers are forwarded. Proxy settings are intentionally ignored;
Tor/onion targets and proxy-based monitoring are not part of this initial release.

## Security-check scope and interpretation

This is a small **read-only exposure/misconfiguration baseline**, not a general CVE
scanner or a proof that a node is secure. It does not attempt RCE, brute-force
passwords, submit transactions, create containers, mutate IPFS data, scan port ranges
or publish Nostr events. Select the service origin explicitly; the node baseline
checks root paths on that one origin and does not automatically explore other ports.

The four node-baseline probes are:

* `GET /.git/HEAD`: classify a Git reference or object-ID fingerprint.
* `HEAD /.env`: check availability without retrieving possible secret contents.
* `POST /api/v0/version` with an empty body: a read-only Kubo version query, not a
  mutating IPFS command.
* `GET /debug/pprof/`: classify the profiling index fingerprint.

Docker uses `GET /version` on the chosen origin. A recognized unauthenticated
service fingerprint fails the check. A 401/403/404/410 indicates denial/absence at
that path from the runner's network position. Redirects, timeouts, connection
refusals, oversized responses, unexpected statuses, and successful generic/SPA
pages are **inconclusive**, not successful security verifications. An exposed
`.env` HEAD result is inconclusive and requires operator investigation; its
contents are deliberately never downloaded. All probes are collected before the
aggregate assertion, so the first failure does not hide the remaining results.

The header baseline expects `X-Frame-Options: DENY/SAMEORIGIN` or a strict CSP
`frame-ancestors 'self'/'none'` directive. A custom ancestor allowlist needs its own
policy-specific feature. Header presence is not a full policy audit. The Nostr
check does not prove WebSocket liveness, event delivery or claimed NIP support.
IPFS availability does not verify the CID's content hash. Private TLS endpoints
still need a trusted certificate valid for their IP; certificate verification is
never disabled to make a check pass.

Requests are sequential, with no retry, a 3-second connection timeout, a 10-second
response deadline, and a 64-KiB body limit. TLS expiry uses a 5-second handshake
limit. DNS ownership and address resolution have separate bounded waits. A large
page that ignores a range request may be inconclusive; select a small health URL
for uptime monitoring. A baseline charges for its four bounded probes during both
dry-run budgeting and execution, rather than hiding them behind one request unit.
The normal Given/Then steps also contribute to the existing per-step budget.

Only findings, status, timings and certificate expiry metadata are added to report
output; response bodies and transport errors are not copied into findings. Targets
and expected public text remain in the feature itself and can appear in existing
feature/report storage, including IPFS. Never enter credentials, tokens or private
content in template inputs. URL userinfo, query strings, fragments, control
characters and Gherkin/template interpolation are rejected.

## API and steps

The existing Schedule V2 auth handler protects both routes:

```text
GET  /api/schedules/v2/templates
POST /api/schedules/v2/templates/render
```

Example render request (a draft only, not activation):

```json
{
  "template_id": "http-uptime",
  "params": {
    "target_url": "https://node.example.com/health",
    "expected_status": 200,
    "max_ms": 3000,
    "authorized": true
  }
}
```

The catalogue is server-owned and rendering is deterministic/network-free.
Parameters use binary JSON keys; unknown fields and unbounded values are rejected.
The render endpoint caps the request at 8 KiB. Budget preview still uses the
existing `/api/schedules/v2/preview` route, and activation uses POST to
`/api/schedules/v2` with the reviewed feature and explicit lock amount.

New supported step signatures live in `steps_monitor.erl` and are discovered by
the existing `steps_*.beam` catalogue; no separate step list is required:

```gherkin
Feature: HTTP uptime for my node
  Scenario: Health stays available
    Given I monitor the authorized URL "https://node.example.com/health"
    When I run the "http-uptime" monitor with options
      """
      {"expected_status":200,"max_ms":3000}
      """
    Then the monitor check must pass
```

Dry-run clauses match only these supported signatures, parse/validate options,
and calculate cost without contacting any target. A live authorization or DNS
failure is inconclusive/failing rather than silently skipped. The UI invalidates
a cost preview after any feature, target, frequency or execution-window edit,
including edits made while a preview request is still pending.

### Exact dry-run dispatch

The runner now honors an optional, side-effect-free `matches_step/1` export
after role filtering. `steps_monitor` claims only its three signatures, so
legacy catch-all `step_dry/6` handlers cannot underquote the four-request node
exposure check. Unmatched legacy steps retain their existing dispatch order.
The runner includes a regression test for routing and the four-request quote;
run it with `rebar3 eunit --module=damage`.

## Testing

From the full OTP monorepo root:

```sh
rebar3 compile
rebar3 eunit --module=damage
rebar3 eunit --module=damage_schedule_templates_tests
rebar3 eunit --module=damage_monitor_target_tests
rebar3 eunit --module=damage_monitor_tests
rebar3 eunit --module=damage_schedule_templates_http_tests
node --test apps/damage/test/scripts/schedule_templates.test.mjs
python3 apps/damage/test/scripts/schedule_templates_browser_test.py --out /tmp/schedule-ui
```

The Python browser test needs Playwright and Chromium. It uses the production
JavaScript functions/CSS, replacing only ES-module imports and transport with
explicit fixtures; it works without browser network access. It is not a live
Cowboy, scheduler, TLS, blockchain or wallet integration test. It covers the
opt-in flow, a seven-day default, editable features, stale previews, create failure
and retry, duplicate-click prevention, pause/resume, catalogue retry, closing during
render, mobile layout and dialog focus restoration. EUnit covers the real Gherkin
parser/catalogue, parameter validation, exact-owner grants, network-range denial,
pinned anonymous transport, probe classification/redaction and API authentication.

## References for the baseline

* Docker daemon access: https://docs.docker.com/engine/security/protect-access/
* Kubo RPC API and public exposure warning: https://docs.ipfs.tech/reference/kubo/rpc/
* NIP-11: https://github.com/nostr-protocol/nips/blob/master/11.md
* OWASP SSRF prevention: https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
