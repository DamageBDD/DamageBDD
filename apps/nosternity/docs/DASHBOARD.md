# Nosternity dashboard server integration

This patch adds a server-rendered dashboard to the uploaded Nosternity Erlang app. Nostr is the primary identity; Lightning LNURL-auth and DamageBDD browser authentication are explicit alternatives. It uses the existing relay and ECAI search index. There is no sample feed or fabricated analytics.

## Apply and run

The patch targets `apps/nosternity` and `apps/damage` from the supplied latest archives. It requires their existing umbrella and dependencies; it is not a standalone replacement for DamageBDD, ECAI, or the release configuration.

```sh
# From the umbrella root, review first, then apply:
git apply --check nosternity-dashboard-server.patch
git apply nosternity-dashboard-server.patch

# Bundled assets are included. Rebuild after changing frontend source:
npm --prefix apps/nosternity/assets ci
npm --prefix apps/nosternity/assets run build

# Use the umbrella's normal build/release process, for example:
rebar3 compile
bash apps/nosternity/test/dashboard/run.sh
npm --prefix apps/nosternity/assets test
```

Alternatively, copy the `apps/` tree from the changed-files ZIP over the matching umbrella. Apply the patch OR copy the files, not both.

Merge `dashboard.sys.config.example` into your release configuration. Replace the public origin and persistent store path. Serve the listener behind HTTPS, preserving `/dashboard`, `/api/nosternity`, `/api/nostr`, `/api/nwc`, `/accounts`, and `/nostr`. The LNURL callback must be reachable from the wallet, without a proxy login wall. Open `/dashboard` or `/`.

The new application dependency declarations include `bbmustache` and `bech32`; ensure the umbrella dependency list includes them. The source archives did not include the umbrella `rebar.config` or lockfile. Existing DamageBDD already uses both libraries. Verification here used OTP 25, Cowboy 2.12, Trails 2.3.1, bbmustache 1.12.2, and the existing Bech32/ECAI dependencies. Frontend versions are locked in `assets/package-lock.json`.

Nosternity must run with the DamageBDD browser-auth worker and existing DamageBDD account services. Missing `nosternity.browser_auth_origin` fails auth closed; the UI reports an unavailable service. Origins are selected by the trusted listener router, not by browser input. Local development permits an exact `http://localhost:PORT` or loopback origin; DamageBDD's existing `cookie_secure` also needs a development-only override for its cookies over HTTP. Public origins must use HTTPS.

`dashboard_enabled = false` disables dashboard, dashboard auth, browser API, and mounted DamageBDD routes and removes the authentication child. The existing relay/search routes remain. `auth_signup_enabled = false` prevents creation of new Nosternity accounts; proved existing accounts still sign in. It does not control DamageBDD's separate signup policy.

## Node branding

Set `node_name`, `node_title`, `node_description`, `node_logo_url`,
`node_favicon_url` and `node_accent_color` in the `nosternity` application
entry of `sys.config`. See [dashboard.sys.config.example](dashboard.sys.config.example)
and the [branding reference](search-relay.md#node-branding) for formats and
validation limits. Restart the node after changing release config.

The same branding supplies the dashboard document title, sidebar, Explore
heading/description, account labels, footer, favicon and accent colour, plus
the note viewer and NIP-11 metadata. Navigation-specific headings still label
the selected feature. Configured text is escaped in templates and client-side
updates. Empty logo/favicon values omit image tags. The bundled symbol remains
as the dashboard logo fallback.

Put public local images in `priv/branding/` before building the release and
refer to them at `/branding/<filename>`. Absolute HTTP(S) image URLs are also
supported; the dashboard permits their configured origins in its image CSP,
while scripts stay restricted to this node. Use HTTPS images on HTTPS nodes.
Only absolute logo URLs are included in the relay's NIP-11 `icon` field.

With `dashboard_enabled = false`, `/` displays the minimal branded home page;
`/dashboard` and dashboard authentication routes remain disabled. Public
branding assets, note views, discovery and search remain available.

## Where to change the UI

Templates live in `apps/nosternity/priv/templates/ui/dashboard/`:

| Fragment | Purpose |
| --- | --- |
| `page.mustache` | Document shell, dialog, script and stylesheet references |
| `sidebar`, `header`, `hero`, `footer` | Navigation and shared layout |
| `feed` | Search, global/following/account/saved feeds, preferences and relay snapshot |
| `auth` | Nostr-first login/signup choices, Lightning and DamageBDD |
| `analytics` | Search/index counts and node-local dashboard measurements |
| `wallet` | NWC connect, balance, invoice creation/payment and DamageBDD connection management |
| `signer` | Browser signer, nsecBunker, public profile and contact-list actions |

All names above use `.mustache`. GET `/dashboard/fragments/NAME` returns only an allowlisted fragment; it never interprets a filesystem path. The shell composes those same fragments on the server. Public note content is escaped text and is signature-checked in the browser. The UI does not embed arbitrary event HTML or third-party profile images.

Edit `assets/src/dashboard.js`, `connections.js`, `core.js`, and `priv/static/dashboard/dashboard.css`. Rebuild JavaScript with the command above and deploy templates and assets together. No CDN is required. CSP allows same-origin assets and secure WebSocket connections for user-selected Nostr relays.

## API conventions

Browser endpoints require cookies with `credentials: 'same-origin'` and `X-Nosternity-Auth: 1`. Mutations require the exact configured `Origin` and JSON Content-Type. A cross-site Fetch Metadata header is rejected. GET session/account/analytics requests may omit `Origin`, but still need the custom header. `/auth/options`, page/assets/fragments and the wallet callback are exceptions. No permissive CORS is installed.

All paths below beginning `/auth/` are relative to `/api/nosternity`.

| Method and route | Request / result |
| --- | --- |
| GET `/auth/options` | Canonical origin, primary provider, supported providers, signup policy and session TTL |
| POST `/auth/nostr/challenge` | `{ "intent": "signup" }` or `login`; returns `challenge_id`, `expires_at`, exact `payload` string and unsigned NIP-98 `event` |
| POST `/auth/nostr/verify` | Body is the exact returned payload; `Authorization: Nostr BASE64(signed_event_JSON)`; sets session cookie |
| POST `/auth/lightning/challenge` | `{ "intent": "signup" }` or `login`; returns `lnurl`, callback, challenge ID and expiry |
| GET `/auth/lightning/callback` | Wallet sends original `tag=login`, `k1`, `action`, plus `sig` and `key`; LUD-04 `status: OK/ERROR`; never sets a browser session |
| POST `/auth/lightning/poll` | `{ "challenge_id": "…" }`; 202 pending, or 200 authenticated session for the bound browser |
| POST `/auth/damage` | `{ "intent": "signup" }` or `login`; proves a live DamageBDD `sessionid` cookie and creates/signs into a separate Nosternity account |
| GET `/auth/session` | `authenticated`, `account_id`, `provider`, `subject`, `expires_at`, `capabilities`; never exposes the Nosternity bearer token |
| POST `/auth/logout` | `{}`; revokes the presented session and clears its cookie |
| GET `/api/nosternity/account` | Authenticated account and saved preferences |
| POST `/api/nosternity/preferences` | Replace all five preference fields; returns updated account |
| POST `/api/nosternity/feed` | `{ "scope":"global", "query":"nostr", "kind":"all", "limit":50 }` |
| GET `/api/nosternity/analytics` | Actual relay status and aggregate dashboard measurements |
| POST `/api/nosternity/events` | Complete signed Nostr event; 202 `{ "accepted":true, "id":"…" }` on acceptance by this relay |

Errors use `{ "error": "reason" }`: 400 invalid request/preferences/event, 401 missing session/invalid proof, 403 origin or capability rejection, 404 account absent, 405 wrong method, 413 oversized body, 415 wrong Content-Type, 429 quota, 503 service/store/capacity unavailable. LNURL callbacks intentionally use LUD-04's status envelope at HTTP 200. Unknown accounts must explicitly choose signup; no email or unproved key creates a Nostr account.

### Nostr signup and login

1. Ask the NIP-07 extension or NIP-46 remote signer for its public key.
2. Request a challenge with the user's `signup` or `login` intent. Retain the browser binding cookie.
3. Display origin and identity for approval. Sign the returned kind-27235 event, refreshing `created_at` to the signing time if necessary. Keep its `u`, `method`, and `payload` tags unchanged.
4. POST the exact payload bytes to `/auth/nostr/verify` with the signed event in the Authorization header.
5. Use the resulting HttpOnly cookie for account actions. Social publication requires a signed event from the session's same Nostr public key.

The server verifies the BIP340 signature, event ID, empty content, timestamp within 60 seconds, exact configured URL, POST method, SHA-256 of the raw payload, and the browser-bound, expiring nonce. The payload includes intent and challenge ID. A submitted proof consumes its matching challenge even if signature verification fails; a mismatched browser binding cannot consume it. It is never published to the relay.

Nosternity signup registers an identity the user already controls. The UI directs new Nostr users to create an identity in a signer first; the server does not generate, import, or store their private Nostr key.

### Lightning signup and login

The QR contains an LNURL-auth challenge, not an invoice. Signup uses `action=register`; login uses `action=login`. The wallet signs the 32-byte `k1` digest directly with secp256k1 ECDSA and returns the DER signature and compressed linking public key. The callback records verification only. The browser must poll using its original binding before a session is issued. A callback replay, expired nonce, wrong action or wrong signature is rejected. No payment is requested.

The Lightning linking key is a separate identity from the Nostr public key. Signing in through another provider switches the Nosternity account. Automatic cross-provider linking is deliberately absent; proving one identity does not prove another. Lightning accounts can store preferences/bookmarks but cannot publish Nostr events without signing into Nostr.

### DamageBDD authentication and NWC

The Nosternity listener mounts the existing DamageBDD browser routes with Nosternity's exact origin:

- GET `/accounts/auth/options` and `/accounts/session`.
- POST `/accounts/login` (`username`, `password`).
- POST `/accounts/signup` and `/accounts/recovery` (`email`).
- POST `/accounts/wallet/challenge` and `/accounts/wallet/verify` retain the existing Aeternity wallet challenge API.
- POST `/accounts/session/logout`.

These routes require `X-Damage-Auth: 1` under their existing policy. The UI provides email login/signup/recovery. DamageBDD's existing confirmation/recovery email flow completes on its configured account service; this patch does not replace password setup or email templates. Configure its public URLs and email delivery in the existing release. The existing Aeternity wallet API remains available to other clients; this dashboard's wallet login button uses Lightning LNURL-auth.

Connecting DamageBDD while signed into Nostr retains Nostr as the primary Nosternity session. The additional DamageBDD session is used only for its services. If there is no Nosternity session, the selected login/signup intent is exchanged through `/auth/damage`. The server accepts no client-supplied account address for that exchange.

The NWC adapter mounts POST `/api/nwc/mint`, `/sessions`, `/revoke`, `/ledger/balance`, `/topup_invoice`, and `/topup_status` beneath `/api/nwc`. Each requires both the same-origin guard and an existing DamageBDD **custodial** browser session, then uses the original DamageBDD authorization and ledger code. The browser adapter does not mount ledger credit/admin mutations. Wallet-only DamageBDD sessions and Nosternity-only sessions cannot use these managed operations.

The UI exposes minting with `max_single_sat` / `max_total_sat`, session listing, and confirmed revocation by `client_pubkey`. It only displays a minted URI if `usable=true`; a pending ledger intent is not reported as success. Existing DamageBDD ledger mode and policies remain authoritative.

External NWC uses encrypted NIP-47 requests directly over the wallet's secure relays. It discovers permitted methods, supports NIP-44 v2 and legacy NIP-04, correlates signed responses to the wallet, client, request and method, and times out without automatic payment retries. Payment requires invoice review and a separate explicit confirmation. Connection links stay in memory. Local disconnect does not revoke permissions at the wallet.

### nsecBunker and social actions

Paste a `bunker://` connection issued by your configured DamageBDD bunker or another compatible NIP-46 signer. Complete its approval, then approve Nosternity's NIP-98 login challenge. The same connection signs public notes, profile updates and contact-list changes. It does not confer DamageBDD wallet or operator authority. Provisioning bunker identities and changing operator vault policy remain in the existing DamageBDD administration tooling; this patch adds the client connection UI, not an unprotected vault-administration API.

The publish endpoint permits kinds 0, 1, 3, 5, 7, 10000 and 30023 only, with a valid event from the authenticated Nostr key. Authentication, encrypted wallet and remote-signing events are not accepted there. Direct protocol `/nostr` behavior is unchanged. An HTTP 202 acknowledges this relay only, not global propagation.

Contact-list updates preserve the latest kind-3 event known to this relay and require review before signing. Users must ensure the relay has their complete list; this implementation does not merge contact lists from every external relay.

## Search, filtering and analytics

Feed scopes are `global`, `account`, `following` and `saved`. `account` and `following` derive the Nostr author from the authenticated session, never a request-supplied key. `following` reads the latest contact list on this relay. `saved` uses server-stored bookmark IDs. The global feed is public and also works for guests.

`kind` is `all`, `1` or `30023`. Queries are bounded to 1,024 bytes. Candidate limit is at most 100 and cannot exceed the configured relay limit. The UI requests 50 candidates, so keep `search_max_limit >= 50`. Relay search/index functionality remains in the existing implementation.

Preference example (all five fields are required):

```json
{"spam":true,"duplicates":true,"muted":[],"words":["airdrop"],"bookmarks":[]}
```

Up to 200 muted author keys, 50 muted words (100 UTF-8 bytes each) and 100 bookmarked event IDs are accepted. Filters cover known promotional phrases, excessive links, repeated normalized text, muted words and muted authors. They are transparent heuristics with possible false positives, not a trained moderation classifier. Filtering affects the response, not storage or other accounts. Guests receive the default spam/duplicate filters.

Feed responses contain `results`, visible `total`, `hidden`, `sampled`, `candidate_count` and `duration_ms` where a search ran. Empty saved/following scopes return an empty sampled result. Counts describe the bounded batch; there is no cursor pagination or whole-network completeness claim.

Analytics show stored events, indexed records, subscriptions, capacity and hydration from the relay, plus aggregate feed/search counts, hidden candidates and mean elapsed request time. Dashboard counters reset with the auth worker. They do not store search terms, identify visitors or count the entire Nostr network.

## Persistence and operations

Accounts and preferences are synced to a private-mode DETS file. Back up that file using your normal Erlang/DETS-consistent backup procedure. Challenges, sessions and rate counters are bounded, node-local memory. Only session token hashes are retained on the server. Restarting the worker invalidates sessions and challenges; account records survive.

This is a single-node session/account store. A multi-node deployment needs sticky routing to the owning node or a shared transactional replacement before distributing login requests. Do not open the same DETS file on multiple nodes. Logout revokes the presented Nosternity session; it is not a global logout of every device. The UI also requests DamageBDD logout and disconnects local signer/wallet connections.

Rate limits use the socket peer, not untrusted forwarding headers. A reverse proxy therefore shares that peer quota; set an appropriate limit and enforce per-client limits at the trusted edge. Auth challenges also have a four-pending-challenge-per-peer bound. Keep access logs from recording Authorization headers, cookies, connection secrets or LNURL callback signatures. The dashboard's responses set no-store/referrer controls.

## Verification and remaining deployment checks

Completed against the supplied sources and real compiled protocol dependencies:

- 16 Erlang auth cases: real BIP340 proofs and DER ECDSA, intent, binding/origin checks, replay/concurrency, expiry, account persistence, preference isolation, revocation, capacities and signup policy.
- Full loopback Cowboy/Gun HTTP round trip: rendered templates/assets, Nostr signup, Lightning callback/poll, cookies, signed publication ownership, spam filtering, account preferences, logout and rejection of unprivileged NWC/Damage exchange.
- DamageBDD origin/policy and Nosternity startup regressions: combined Erlang run passed 48 tests.
- Three jsdom interaction tests with real Nostr signatures: all workspace fragments, escaped content, explicit signup approval, publication, bookmarks/logout, DamageBDD signup/recovery payloads. HTTP in these browser tests is stubbed; the Erlang HTTP test exercises the actual listener.
- Frontend bundle builds from locked dependencies; the patch is checked against the uploaded-source baseline.

A full umbrella release build was not possible from these three app archives alone. Live SMTP/account confirmation, a real browser extension, DamageBDD nsecBunker approval, funded NWC/ledger operations and a phone wallet through your public HTTPS proxy were not exercised. Run those checks in your deployment before opening signup. No test sent money, modified a production account or imported private identities.

Protocol references: [NIP-98](https://github.com/nostr-protocol/nips/blob/master/98.md), [NIP-07](https://github.com/nostr-protocol/nips/blob/master/07.md), [NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md), [NIP-47](https://github.com/nostr-protocol/nips/blob/master/47.md), and [LUD-04](https://github.com/lnurl/luds/blob/luds/04.md).

## Input provenance

The changed-file bundle contains only additions/modifications, not the complete uploaded apps. Baseline SHA-256 values:

```text
751211f162a33b2e756472c73d21e5d8d782635349c04c0403362a3ef3975f70  latest-nosternity.tar.gz
5a15a315f8759fe5a7966671a247e800ae647ec635220042203ef6d1b881ff1e  latest-damage.tar.gz
bf881051fd6051a714508dd636d6cda222322b3ba24fb5e0cdc6ca975307e176  latest-ecai.tar.gz
```

No ECAI source modifications are required. Its existing relay index is reused.
