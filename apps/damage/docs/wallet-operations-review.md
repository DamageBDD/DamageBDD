# Wallet operations and authentication review

## Scope and deployment decision

Reviewed the uploaded `latest-damage.tar.gz` after applying the prior composer,
sidebar, native WebDriver tests, and managed-runtime patches. The archive SHA-256
is `d1b507eff0673f1cfdae60346b159754a99d0b1201a2e0db968d316f309012ed`.
All source anchors below refer to that **pre-auth-change baseline**, not the older
standalone Erlang attachments. Line numbers will move after applying the patch.

This is a source-level review, not a penetration test or chain/payment audit.
There were no real wallet, SMTP, CLN or chain calls. Production deployment needs
compilation and the live acceptance checks at the end of this document.

**Primary patch:** modernises browser authentication, establishes a restricted
wallet-only session, and quarantines the existing `/tx/` HTTP handler. It retains
managed execution through `/execute_feature/`. It does not implement a new paid
wallet execution protocol.

**Separate optional patch:** `damagebdd-nwc-payment-quarantine.patch` disables
outgoing NIP-47 invoice payments through the two reviewed dispatch entry points.
It is containment, not a ledger/payments repair. The primary auth patch alone does
not close that relay payment path. Review this separately before running a funded
NWC service. No running node is modified by these downloadable patches.

## Findings and disposition

### 1. Critical: relay payment handler bypasses the ledger policy check

Baseline anchors:

- `src/damage_nwc_listener.erl:642–650`, `handle_new_request_event/2` invokes
  `damage_nwc_request_handler:handle_nip47_request/1`.
- `src/damage_nwc_request_handler.erl:84–107`, `handle_pay_invoice/2` checks that a
  client public key is present, then calls `damage_cln:pay_invoice/1`.
- `src/damage_nwc_wallet.erl:417–474` contains a separate `authorize_amount_msat`
  implementation, but the listener's selected handler does not call it.

The reviewed path has no owner/ledger resolution, revocation, expiry, quota,
balance reservation or settlement debit before/after that CLN call. A decryptable
request is not sufficient authorization to spend the node's Lightning balance.
The default decoder overwrites the decoded request's client-public-key field from
the event (`src/damage_nostr.erl:1215–1232`); this finding does **not** rely on being
able to inject a different client key through that default decoder.

**Disposition:** the primary patch prevents new wallet-only browser sessions from
minting/mutating NWC state, but does not change existing relay clients. The optional
quarantine patch rejects `pay_invoice`, removes its advertisement from both
information handlers and the listener, and has no runtime re-enable flag. It does
not revoke copied NWC secrets or settle old payments.

### 2. High: the alternative NWC payment path is not an atomic fix

Baseline anchors: `src/damage_nwc_wallet.erl:181–231` and `:417–490`.

The alternative handler reads policy/balance, pays CLN, and then invokes
`debit_after_payment`. Concurrent calls can observe the same balance/remaining
quota because there is no atomic reservation before payment. Fees are reported
but not reserved with the invoice amount. The debit result is discarded, and
`user_signed`/`operator_signed` branches return `ok` without this implementation
committing a debit. The height helper can fall back to zero on failure, weakening
expiry enforcement.

**Disposition:** do not repair finding 1 merely by rerouting requests to this
handler. The optional patch intercepts `pay_invoice` here too. A repaired service
needs durable idempotency, atomic amount-plus-fee reservations, explicit unknown
payment state, reconciliation and fail-closed policy/height reads. Do not retry
an uncertain payment as a fresh payment or refund a reservation until its outcome
is established.

### 3. High: `/tx/` does not bind the paid work to a verified transaction

Baseline anchors: `src/damage_http.erl:257–258`, `:1996–2087`, and
`priv/static/js/main.js:2066–2079`.

The route is explicitly public. Its feature/signed-transaction branch posts the
submitted transaction, accepts a successful contract result with wildcard
`caller_id`/`contract_id`, and then executes separately supplied feature, address,
concurrency and context. A successful transaction is not proof that it authorises
those exact inputs. Other actions under the same route prepare/finalize channels.
The dashboard wallet branch calls `ensureChannel` before an explicit payment
review and then returns ahead of the older transaction-signing code.

**Disposition:** the primary patch returns HTTP 409 for **all** `/tx/` callers,
before those action handlers run. The dashboard no longer calls `ensureChannel`
when Run is selected. Wallet-only execution is disabled, with an explanation.
Managed authenticated `/execute_feature/` remains on its existing path.
This is deliberately a compatibility break for `/tx/` users, including any
existing channel setup clients. Do not label the change as full wallet execution
support or silently restore the old handler.

### 4. High: proof of wallet ownership and custody were conflated

Baseline anchors: `src/damage_auth.erl:63–88`,
`src/damage_accounts.erl:489–502`, `priv/static/js/wallet-switcher.js:1–145`.

The generic `ae1` resolver uses `with_identity_account`, which retrieves the
account and may hydrate its private key into request/wallet-process state. The
legacy metadata-signature login does not enforce a server-issued nonce, purpose,
audience or one-time use; it also emits a different legacy token format. The
browser code stores multiple bearer credentials in localStorage and switches them
as if choosing a connected wallet were a sufficient account transition.

**Disposition:** browser sign-in now uses node-issued `ds1` sessions. A wallet
challenge is bound to the configured origin, network, account, nonce, expiry and
browser cookie. Verification consumes it once and accepts only a valid signature.
The wallet `ds1` resolver does not query `identity_server`, removes stale key/name
fields, and denies unsupported protected routes. An explicit switch is a new
login, not linking, merging or fallback to another saved account. Legacy arbitrary
metadata authentication is rejected.

Legacy `ae1` tokens remain an **independent API trust path** with their previous
custody semantics. Type/version/audience/lifetime checks are tightened, but this
patch does not convert them into scoped wallet-only credentials or add universal
revocation. An account capable of issuing/using a legacy API token can still enter
that older authorization path; the new restrictions describe `ds1` wallet browser
sessions, not every possible signature-based credential accepted by the system.

### 5. High: NWC mode configuration does not match its documented intent

Baseline anchor: `src/damage_nwc_http.erl:135–144`, `ledger_mode/0`.

The comment says the default is `user_signed`, but the fallback returns
`server_signed`. This helper recognises explicit server/operator values, not an
explicit user-signed value. It differs from the helper in `damage_nwc_wallet`.
Additionally, returning registration/setup intents without a durable pending
client secret, signing, confirmation and resumption path is not usable end-to-end
wallet-only NWC provisioning.

**Disposition:** the primary patch does not change the global ledger default or
pretend to complete those intents. Wallet `ds1` sessions cannot enter any NWC
endpoint. Managed NWC operations retain their existing implementation and still
need this review. Changing a sys.config value alone is not sufficient to enable a
working non-custodial path.

### 6. Medium: nominally read-only balances can reach custody-dependent state

Baseline anchors: `src/damage_balance_cache.erl:299–302`, `:385`;
`src/damage_accounts.erl:996–1070`.

The composite balance read fetches the NWC ledger as well as public AE/DAMAGE data.
The wallet snapshot resolves the user ledger/registry. Those calls do not establish
a pure public-key-only path for an external wallet.

**Disposition:** the primary patch adds a separate public-chain-only snapshot for
wallet sessions. It does not call the composite NWC cache/resolver. Lightning
ledger availability is reported as unavailable rather than zero; public upstream
failures also remain unavailable. The managed snapshot is retained.

### 7. Medium: UI state and secret persistence obscure authentication outcomes

Baseline anchors: `priv/static/js/main.js:575–601`,
`priv/static/js/wallet-switcher.js:18–45`, `priv/static/js/nwc.js:126–154`.

An ancestor keydown handler can make Enter in a nested form trigger login. Multiple
login/signup listeners complicate duplicate-submission control. LocalStorage
retains multiple bearer tokens and the last NWC connection URI, which contains a
spending credential rather than just a public wallet address.

**Disposition:** independent form submit handlers, one in-flight guard, visible
failure/retry states, explicit connection/signature phases, cancellation before
verification, and stale-reply suppression. Tokens are retained in JS memory and
an HttpOnly cookie, not localStorage. NWC URI caching is memory-only and cleared on
auth changes. Logout failures remain visible in the wallet panel and keep the
session rather than reporting a false success.

## Wallet-only operation matrix after the primary patch

| Operation | Result | Signing authority used |
|---|---|---|
| Connect extension/mobile wallet | Address/challenge only; not logged in | None |
| Sign in | Review and sign one expiring login message | Selected user's wallet |
| Edit/export feature | Available in browser | None |
| Generate/static-validate feature | Available via explicit authoring APIs | No transaction signer |
| Read AE/DAMAGE balance | Public-chain reads only | None |
| Show/copy receiving address | Available | None; receipt is not a spend |
| View account history/analytics | Not enabled as a verified wallet-only API path | None; protected routes denied |
| Run/pay for feature | Unavailable; no automatic channel or transaction | None |
| Transfer/swap/open channel | Unavailable in dashboard | Use wallet app independently |
| Save account context/schedules | Unavailable | Needs explicit storage/delegation design |
| NWC create/revoke/credit/top-up | Unavailable for wallet `ds1` | No server key loaded |
| Billing/node administration | Unavailable for wallet `ds1` | Existing managed role checks remain separate |
| Disconnect/sign out | Revoke current `ds1`, clear cookie; no alternate-account fallback | No transaction signer |

A disabled UI button is not an authorization boundary. `damage_wallet_policy`
enforces a narrow allowlist within `damage_auth`; public handlers and handlers
using another auth path are not automatically covered. Node-shell calls remain
operator-trusted. This is not a full application-wide authorization retrofit.

## Remaining authentication work

Email confirmation/password-reset tokens retain the existing encrypted
`{email, expiry}`-style payload without a distinct purpose or durable one-use
record (`src/damage_accounts.erl:431–463`, `:504–639`). Resetting a password does not
revoke every prior `ae1` token or `ds1` session. The primary patch modernises those
forms and limits URL/referrer exposure; it does not fix this token lifecycle.

The new canonical `/accounts/session/logout` revokes `ds1`. The legacy
`/accounts/logout` handler only clears the cookie; its older stateless semantics
remain unchanged. Integrations must migrate to the canonical browser endpoint
rather than infer server revocation from a legacy logout response.

Legacy login endpoints are not moved behind the new per-peer attempt limiter.
Apply an appropriate edge policy and review their abuse controls separately.
Complete authentication/transaction logging and third-party script/CSP review
also remains necessary; the patch makes no claim to remove all application-wide
credential exposures.

Because existing dashboard consumers use Authorization headers, GET
`/accounts/session` returns the bearer token to same-origin JS. HttpOnly on the
cookie therefore does not make the session inaccessible to an XSS payload. No
localStorage bearer persistence reduces persistence, not the impact of arbitrary
same-origin script execution. Cookie-only consumer migration plus comprehensive
CSRF/CSP and session-revocation changes is a separate coordinated migration.

## Requirements before re-enabling wallet-only payments

Create a server quote that binds authenticated account, network, contract,
method, receiving node, integer amount and fee limit, exact feature-byte hash,
concurrency, resolved execution-context digest, expiry and unique operation ID.
The wallet review must display the significant payment data separately from login.

Verify that the signed transaction exactly matches the quote and expected signer
before posting. Verify accepted chain execution and spend linkage before running
work. Atomically consume the quote once; duplicate requests must return the same
operation/result, not execute twice. Preserve a durable status for uncertain chain
or Lightning outcomes, with a reconciliation path. Never use a successful unrelated
transaction as evidence of payment for an arbitrary feature. Unattended schedules
need bounded, revocable delegation or escrow; an absent browser cannot sign later.

For NWC, implement confirmed client registration, durable secret/pending-intent
handling, owner-bound session resolution, atomic quota/balance/fee reservations,
revocation/expiry checks and settlement reconciliation before restoring outgoing
payments. A wallet login must never silently enable custody as a fallback.

These requirements follow OWASP's separation of authentication from transaction
authorization, significant-data review, server-side enforcement and unique,
limited-lifetime authorization. References:

- https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
- https://github.com/superhero-com/superhero-wallet/blob/develop/docs/deep-link-schema.md

## Acceptance gates not exercised in this environment

Compile the full OTP umbrella; run the two new EUnit modules and actual native
Common Test profiles. Verify real Sidekick and mobile signatures against the node's
`vanillae` implementation, including rejecting false signatures, account changes,
wrong origin/network, expired/bad/replayed proofs and stale callback states.

Exercise exact-origin and Secure/HttpOnly/SameSite cookie behaviour through the
actual proxy. Verify new logout and node restart invalidate sessions; document
multi-node sticky routing. Use dedicated staging identities to verify signup,
confirmation, recovery and existing API-token compatibility. Exercise direct HTTP
attempts to bypass disabled UI controls and confirm denied requests never invoke
custodial lookup, signer, channel, invoice, payment or feature execution functions.

Screenshots and Chromium DOM checks in the delivered verification record use
simulated origin, Storage/reload, Sidekick and auth/SMTP responses. They do not prove
these deployment-level properties. Outgoing-payment containment likewise needs
EUnit and integration verification before it is relied upon for a funded node.
