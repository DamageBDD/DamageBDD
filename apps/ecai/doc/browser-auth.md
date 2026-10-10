# ECAI dashboard: shared DamageBDD browser authentication

## What was reviewed

The implementation is based on the two uploaded application archives, not a
remote checkout or earlier generated patch. Archive SHA-256:

- latest-ecai.tar.gz: `349bb5212d1b8d3f07620c0778e33321f799635806e089301c8ed2e998673bb7`
- latest-damage.tar.gz: `d4bc7fc50176a46c0a6288a6d5939ce58fb21175ef5f231bd22520c8293e86ed`

Source findings and the corresponding integration decisions:

| Uploaded source | Finding | ECAI integration |
| --- | --- | --- |
| `apps/damage/docs/auth-wallet-flow.md` and `src/damage_browser_auth.erl` | Browser sessions are revocable, node-local `ds1` tokens; connecting and authenticating a wallet are separate. | Use the shared browser service, not the legacy email API or a new token store. |
| `apps/damage/src/damage_browser_auth_http.erl` | The eight browser endpoints enforce a configured origin; wallet challenges bind origin, account and a browser cookie. | Mount the existing routes with a trusted ECAI listener tag and its own exact configured origin. |
| `apps/damage/src/damage_accounts.erl`, `browser_action/2` | Signup and recovery invoke existing email workflows. Confirmation/reset links use the canonical DamageBDD `api_url`. | Reuse these handlers; do not invent a second signup API or rewrite email links. |
| `apps/damage/priv/static/js/auth-ui.js`, `auth-wallet-loader.js`, `wallet.js` | Separate email/signup/recovery panels; lazy wallet loading; explicit signature; Superhero app callbacks. | Render the shared modal and mount live DamageBDD assets under an explicit ECAI prefix. |
| `apps/damage/src/damage_auth.erl`, `resolve_oauth/2` | Wallet sessions deliberately omit managed keys and force `node_admin=false`, including for a configured admin address. | Preserve the session's authority rather than recomputing it from address membership. |
| `apps/ecai/src/ecai_index_pool_http.erl`, `actor/1` | Before this change, explicit bearer resolution was followed by raw address-only admin membership. | Require a server-authenticated, admin-authorized, non-wallet session before funded-indexing operations. |
| `apps/ecai/src/ecai_code_admin_http.erl`, `from_json/2` | Before this change, mutations checked bearer presence after the normal auth callback. | Resolve the exact bearer again and bind it to the same authorized actor; do not accept cookie fallback. |

The review is scoped to browser-auth integration, not a comprehensive audit of
all existing public endpoints, Lightning settlement or account storage.

## Dashboard behavior

The top bar offers **Sign in**, **Create account** and **Connect wallet** while
signed out. Guests can dismiss the dialog and continue public browsing. Signed-in
users see their session kind, **Switch account** and **Sign out**.

**Create account** submits only the email address to `/accounts/signup`. The
separate form cannot accidentally submit the password login. Success means a
confirmation was requested, not that an account is confirmed or signed in.
The existing DamageBDD email confirmation and password setup remain authoritative.
Confirm using that email, then return to ECAI and sign in. Recovery follows the
existing `/accounts/recovery` email workflow. Mail delivery, registration policy,
identity storage and canonical confirmation pages still depend on DamageBDD.

**Email sign-in** posts to `/accounts/login` and accepts only the current browser
session response through the shared `TokenManager`. `/accounts/session` restores
the revocable bearer into memory after reload. `/accounts/session/logout` revokes
it server-side and clears the cookie. A failed sign-out is shown as unconfirmed;
it does not pretend that the browser is safely signed out.

**Wallet sign-in** is connect → challenge → review message → explicit signature →
server verification → restricted session. Connecting alone does not log in, sign a
transaction, pay, or open a channel. Browser-wallet account changes are checked
before signing. The wallet adapter is loaded lazily, so unavailable/stale wallet
exports do not disable email signup/login. The separate Superhero app handoff
returns to `/dashboard` on the exact ECAI origin. Callback nonce, expiry, phase and
expected account checks are retained; callback fragments are scrubbed before
normal dashboard navigation. Default DamageBDD callback behavior remains `/`.

Switching starts a new sign-in, not account linking. A failed or cancelled switch
before verification leaves the existing account intact. A successful switch
reloads the dashboard. Closing the modal invalidates pending client work; it cannot
undo a login request the server has already processed. Timed-out requests have
an unknown outcome and require session inspection, not blind retries.

## Permissions stay explicit

| Session | Public search/chat | Protected indexing/private APIs | Code admin / funded indexing |
| --- | --- | --- | --- |
| Guest | Existing public behavior | Sign-in required | Denied |
| Verified wallet | Existing public behavior; identity shown | Not enabled by this integration | Denied, even for an admin address |
| Managed email | Existing public behavior | Existing server-side ownership/authorization | Existing node role, allowlists and feature gates |

The wallet UI explains the restriction and skips protected queue/admin polling,
rather than triggering misleading L402 challenges. It never treats a wallet
address as spending authorization. The policy addition is only the metadata
read `GET /ecai/auth/session`. Known public handlers that bypass `damage_auth`
(e.g. existing Yelp operations) remain a separate security boundary; frontend
disabling is not server authorization.

`ecai_node_admin:session_is_node_admin/1` requires server-derived authentication,
a positive node-admin flag, current configured membership and a non-wallet mode.
The code-review independent-publisher rule and funded-job budget/payment gates
are unchanged. No CLN, ledger, channel or payout configuration is modified. The admin HTTP
serializer also now preserves JSON true/false/null rather than emitting strings:
the old string "false" is truthy in browser eligibility/configuration displays.
This is a payload-type correction, not a publication permission change.

Tokens stay in memory and the existing HttpOnly session cookie, not localStorage.
The same-origin session endpoint intentionally returns a bearer for existing API
consumers. This is NOT an HttpOnly-only or XSS-proof design. Session events omit
tokens. Late session-restore/API responses are discarded after identity changes.
Legacy stored tokens are not a fallback. Browser sessions still expire, are
node-local and are lost when the existing auth service restarts; use sticky
routing for a multi-node HTTP deployment.

## Configuration and deployment

Merge this setting into the existing ECAI application environment:

```erlang
{ecai, [
    {browser_auth_origin, "https://ecai.damagebdd.com"}
]}.
```

Use the actual public scheme/host/port, not the internal Cowboy listener address.
Do not replace `damage.browser_auth.origin` with the ECAI origin. The DamageBDD
listener retains its current origin. The ECAI listener accepts only its own
configured origin; request Host/forwarding headers do not select an authority.
Missing ECAI origin yields HTTP 503 `auth_origin_not_configured`; mismatched browser
mutations yield HTTP 403. HTTPS is required except for the existing localhost
HTTP development allowance. Cookie Secure defaults remain unchanged.

See `priv/config/browser_auth.example.config`. The existing `damage_browser_auth`
supervisor child must be running. Deploy both application patches together,
compile and perform a planned restart/release upgrade that reloads both router
and modules. Existing sessions may expire on restart. No production database
reset is needed. Hard-refresh `/dashboard` after deployment.

The ECAI router exposes only the eight shared browser-auth endpoints and the
explicit auth assets. It does not mount the entire DamageBDD account/admin
router. Shared assets are served from DamageBDD's `priv/static` at
`/ecai/auth-assets/`; they are not copied into ECAI. The existing separate simple
and advanced indexer pages retain their older login flows and legacy routes.
This change migrates the main console only.

The old main-console `consoleLoginForm` and its duplicate login/logout handlers
are removed. The account/session UI is separate from the API Explorer so session
bearers are not displayed in its raw-response panel.

## Tests

```bash
node --check apps/ecai/priv/static/js/ecai-console.js
python3 apps/ecai/test/test_console_contract.py
python3 apps/ecai/test/test_indexing_rewards_contract.py
python3 apps/ecai/test/test_index_pool_contract.py
python3 apps/ecai/test/test_browser_auth_contract.py
node --experimental-vm-modules --test \
  apps/damage/test/scripts/auth_model.test.mjs \
  apps/damage/test/scripts/auth_module_loading.test.mjs \
  apps/damage/test/scripts/auth_ecai_integration.test.mjs

# Playwright + Chromium required; uses fake auth/email/wallet providers:
python3 apps/ecai/test/test_dashboard_auth_browser.py
# Hosts that prohibit HTTP navigation can run the explicit DOM-only adapter:
python3 apps/ecai/test/test_dashboard_auth_browser.py --dom-only
python3 apps/ecai/test/test_code_metrics_browser.py
python3 apps/ecai/test/test_wikimedia_picker_browser.py
python3 apps/ecai/test/test_index_pool_browser.py

rebar3 compile
rebar3 eunit --module=damage_browser_auth_tests,damage_wallet_policy_tests,damage_browser_auth_origin_tests,ecai_browser_session_tests
rebar3 eunit --app ecai
```

The new main-console browser suite uses real production templates and JS modules
with mocked endpoints and wallet transport. In DOM-only mode it additionally
simulates origin/storage/cookies/reload: it does not validate real browser cookie
policy, Cowboy routing or cryptographic proofs. Older feature-browser fixtures
have been migrated to the same shared auth modules and ds1-shaped sessions.

Erlang tests added here check per-listener origins, missing configuration,
request-header gates, wallet policy, secret-free session metadata and non-wallet
admin authority. They require compilation with the normal rebar test profile.
Live SMTP confirmation/recovery, a real installed browser/mobile wallet,
Cowboy authentication and real-node admin permissions remain deployment tests.
No real account, wallet, Lightning payment, Git push or channel operation was
performed while developing the patch.
