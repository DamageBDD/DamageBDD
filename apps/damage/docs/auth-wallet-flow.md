# Browser authentication and wallet-only operations

## Scope and baseline

This change is incremental on the supplied `latest-damage.tar.gz` plus the combined
composer/sidebar patch, the WebDriver tests patch, and the managed-WebDriver patch.
The source archive SHA-256 is
`d1b507eff0673f1cfdae60346b159754a99d0b1201a2e0db968d316f309012ed`.
No user node, funded wallet, chain transaction or mail service was contacted.

Browser connection, authentication, and spending authority are separate states.
Email sign-in retains the managed/custodial operations path. Wallet sign-in proves
ownership without loading a user key from `identity_server`. This is a session
authority boundary, not proof that the node has never held that account's key; it
does not delete existing custodial key material. This patch deliberately
does **not** complete wallet-only paid execution, transfers, scheduling or NWC setup.

**Compatibility change:** `/tx/` is quarantined with HTTP 409, for all clients.
The old public handler mixed transaction submission and execution without binding
all the requested work to a validated payment. There is no switch to restore that
unsafe path. Existing integrations using it must not deploy this patch blindly.
The normal authenticated managed `/execute_feature/` path is retained.
See [the wallet operations review](wallet-operations-review.md) for the independent
NWC payment-policy bypass and the separate optional outgoing-payment quarantine.

## User experience

Email, Create account, and Wallet are independently labelled panels. Each form has
one submit handler; Enter in signup/recovery cannot trigger the email login form.
Requests show progress, prevent duplicate submissions, preserve an entered email
on failure, and display server errors as text. Passwords support browser password
managers and a visibility toggle. Confirmation/reset pages have matching styling,
inline errors and a sign-in next step rather than automatic authentication.

Wallet flow: **connect → receive challenge → review message → explicitly sign →
server verification → new session**. Connecting alone never signs a message,
opens a channel, submits a transaction or reveals an authenticated dashboard.
The selected browser-wallet address is checked again immediately before signing.

The separate Superhero app button uses the documented address and sign-message
links. It omits `encoding` for a plain UTF-8 message. Return data lives in a fragment,
is checked against per-tab random state, phase, time and expected account, and is
removed from the address bar before further work. The browser-cookie-bound server
challenge still has to verify. There is no trusted-address-only callback shortcut.
Mobile handoff through an actual installed wallet has not been exercised here.

Switching is an explicit new sign-in, not account linking. A failed or cancelled
switch retains the current account. Save unsaved feature drafts before switching:
a successful identity change reloads server-rendered panels to avoid stale data.
“Keep my current account” abandons a switch. Disconnect means sign out from this
browser session; it does not revoke existing NWC clients, remove extensions, or
prove that the wallet provider has revoked its own connection permissions.

## Server and storage model

`damage_browser_auth` is a supervised, bounded, node-local service. It stores random
challenge IDs and opaque browser sessions with monotonic expiry. Session tokens
are `ds1.<64 hex characters>`; only their SHA-256 lookup keys are retained in the
service state. Wallet challenges include origin, network, account, random nonce,
expiry and a non-payment statement. Verification consumes the challenge atomically
before checking the signature. Wrong-origin/browser bindings fail without creating
a session; bad signatures and repeated submissions cannot reuse a consumed proof.

The HTTP API rejects cross-origin browser mutations and requires `X-Damage-Auth: 1`.
The configured origin is never inferred from arbitrary Host/forwarding headers.
Bodies are bounded, attempts are rate-limited per direct peer, and responses use
no-store and no-referrer. Behind a proxy the peer limit is shared by that proxy;
use an appropriate edge rate limiter rather than trusting arbitrary client IP headers.

| Endpoint | Purpose |
|---|---|
| GET `/accounts/auth/options` | Public origin/network configuration |
| GET `/accounts/session` | Restore and describe the current browser session |
| POST `/accounts/login` | Password check followed by a revocable managed session |
| POST `/accounts/signup` | Request the existing email-confirmation workflow |
| POST `/accounts/recovery` | Request the existing managed-account reset workflow |
| POST `/accounts/wallet/challenge` | Create the browser-bound wallet challenge |
| POST `/accounts/wallet/verify` | Consume proof and create a restricted wallet session |
| POST `/accounts/session/logout` | Revoke the browser session and clear its cookie |

`sessionid` remains an HttpOnly, SameSite=Lax cookie; Secure defaults to true.
Existing dashboard modules require an Authorization header, so the same-origin
session endpoint also returns the bearer token to `TokenManager`, in memory.
**This is not an HttpOnly-only/XSS-proof session design.** Same-origin malicious
JavaScript can obtain that token. Migrating every consumer to cookie-only requests
with comprehensive CSRF protection and a suitable CSP remains separate work.
Tokens are not persisted in localStorage, and `ds1` is rejected in URL query auth.
Legacy browser-token keys are removed. NWC connection URIs are held in memory only
and cleared on authentication changes; they are spending credentials, not ordinary
wallet addresses. Clipboard/external app copies are outside that cleanup.

Browser sessions expire, can be revoked by the new logout endpoint, and are lost
on node restart. Use sticky routing for a multi-node deployment. There is no
persistent/distributed revocation store. A restart should fail closed, not silently
fall back to a saved email account. Password reset does not yet revoke every
previous token/session: see the remaining work in the review. The legacy
`/accounts/logout` route only clears the cookie; browser integrations must use
`/accounts/session/logout` to obtain server-side revocation.

Legacy `ae1` API tokens remain supported independently, with type/version/time,
nonce-length, audience and address checks added. They retain their original
stateless authorization/custody semantics. They are not converted into restricted
wallet browser sessions and cannot be claimed to have `ds1` revocation guarantees.
Clients using unbounded lifetimes or another audience will need updated tokens.

## Wallet-only capability boundary

`damage_auth` derives wallet mode from the server session, never from request JSON.
It does not call `identity_server:get_account` on this path, removes stale key/name
fields, and does not grant node-admin UI privileges. `damage_wallet_policy` allows
only specific reads, authoring endpoints and logout. Unknown protected routes are
denied. Existing endpoints that are public or do not use this auth adapter require
separate review; this is not a universal authorization framework retrofit.

| Operation | Wallet-only browser session | Managed email session |
|---|---|---|
| Describe/edit/generate/static validate BDD | Supported | Supported |
| AE/DAMAGE balances and receiving address | Public-chain reads only | Existing account snapshot |
| Run/pay for a feature | Denied before execution | Existing managed execution checks |
| Transfer/sign a transaction/open a channel | Denied | Existing supported managed operations |
| Persist account context or schedules | Denied | Existing managed checks |
| Create/mutate NWC sessions and ledgers | Denied | Existing managed implementation; review required |
| Billing administration | Denied | Existing billing role checks |

The composite balance cache also looked up NWC/registry state. The new wallet-only
read uses public chain endpoints, without the composite cache or NWC resolver.
Upstream read failure is unavailable, not proof of zero balance. UI controls explain
the restriction; both click and form-submit paths are guarded. The server policy
is authoritative even if a user modifies the DOM.

## Configuration and deployment

Merge `priv/config/browser-auth.sys.config.example` into your existing `{damage,[...]}`.
Set the exact public HTTPS origin and network. Local HTTP is limited to localhost,
127.0.0.1 or ::1; set `cookie_secure=false` only for local development. Existing
`api_url` is used if an explicit browser origin is omitted. Default challenge TTL
is 180 seconds; browser TTL is 3600 seconds. Limits are documented in the sample.

Deploy UI and backend together, compile the full umbrella and restart the node to
start the supervisor child. Existing browser users sign in again. Retain the normal
managed WebDriver configuration from the previous patch; no global browser tools
or new package installation is required by the authentication code.

```
rebar3 compile
rebar3 eunit --module=damage_browser_auth_tests
rebar3 eunit --module=damage_wallet_policy_tests
node --test apps/damage/test/scripts/auth_model.test.mjs
rebar3 ct --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/managed-auth-fixture.config
```

The managed auth fixture serves production templates, CSS and UI/adapter modules
with fake Sidekick and fake auth/email responses. Eight native Gherkin scenarios
cover form separation, the explicit wallet proof step and session transitions.
It never contacts a real wallet or SMTP service. For Android, review
`appium-auth-fixture.config` and the existing managed runtime sys.config; the Android
emulator reaches the host fixture at 10.0.2.2:8766. A physical device needs an
appropriate host address or adb reverse. The fixture script must be reachable from
the test host, not installed on the production public router.

```
python3 apps/damage/test/scripts/auth_browser_test.py --out /tmp/auth-ui
# Only in browser sandboxes that prohibit HTTP navigation:
python3 apps/damage/test/scripts/auth_browser_test.py --dom-only --out /tmp/auth-dom
```

The second mode explicitly simulates origin, Storage and reload. It is a DOM
cross-check, not browser-cookie, real navigation, Selenium/Appium, server or crypto
verification. EUnit uses a mocked signature adapter; separately verify actual wallet
signatures, origin/cookie behaviour through your proxy, replay rejection, API-token
compatibility, and SMTP confirmation in staging before production deployment.


## ECAI main-console integration

The ECAI listener calls `damage_browser_auth_http:trails(ecai)` with a static
router tag and requires an explicit `ecai.browser_auth_origin`. DamageBDD's
`trails/0` keeps its original configured origin. The listener tag is never
inferred from an incoming Host or Origin header. ECAI renders the shared auth
modal and mounts explicit live assets, with guest dismissal and `/dashboard`
mobile callbacks. Default DamageBDD auto-open and `/` callback behavior remain.

Only `GET /ecai/auth/session` is added to wallet-only protected-read policy.
Code-admin and funded-indexing callers must preserve server-derived wallet mode
rather than elevating an account by address membership. They do not gain any
wallet-only spending authority. The shared TokenManager now ignores session
restore responses from before a successful sign-in or logout. See
`apps/ecai/doc/browser-auth.md` for integration and deployment details.
