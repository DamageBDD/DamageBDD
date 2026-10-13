# Enterprise invoices and recurring retainers

This patch adds a private, node-local commercial invoice service to the uploaded DamageBDD application. It does not replace `damage_invoicing`, `/invoices`, DAMAGE credit top-ups, Core Lightning payment requests or the NWC ledger.

The main workflow is:

```
Customer + recurring plan -> service-period draft -> approval / numbering
                         -> PDF -> durable email queue -> SMTP acceptance
                         -> independently verified payment recording
```

The feature is disabled by default. The examples and separate private customer seed are paused, with automatic sending off. Merely applying the patch or importing the seed does not create invoices or send messages.

## Existing infrastructure reused

| Existing component | Integration |
| --- | --- |
| `damage_sup` | Supervises the new invoice service. Startup does not require an unlocked vault or reachable SMTP relay. |
| `damage_schedule_index` | Its existing heartbeat sends a nonblocking tick to billing. Billing processes at most one tick per minute. |
| `damage_access_token` | Verifies existing signed account Bearer tokens. No separate login system. |
| `damage_auth:is_node_admin_account/1` | Determines node-admin membership using existing trusted configuration. |
| `secrets:encrypt_bound/2`, `decrypt_bound/2` | Encrypt the private state snapshot and PDFs using the existing node identity. |
| `damage_utils`, `gen_smtp`, `mimemail` | Reuse existing relay configuration, vault-held SMTP password and MIME stack. |
| Cowboy / Trails / dashboard Mustache / TokenManager | New private API and Invoices tab in the existing dashboard. |

Billing deliberately does **not** pass financial records through scheduled Gherkin execution, public execution reports, IPFS uploads, token-balance checks or on-chain scheduling. The existing scheduler supplies the heartbeat; the billing service owns its private calendar and persistence.

## Apply and validate

From the monorepo root, apply the patch OR extract the source overlay, not both:

```sh
git apply --check /path/to/damage-enterprise-invoicing.patch
git apply /path/to/damage-enterprise-invoicing.patch
rebar3 compile
rebar3 eunit --module=damage_invoice_model_tests,damage_enterprise_invoices_tests,damage_invoice_http_tests,damage_mail_tests
```

The supplied archive contained `apps/damage`, not the complete monorepo build/dependency configuration. See `ENTERPRISE_INVOICES_VALIDATION.md` for checks actually performed and checks still required. Run compilation, EUnit and a staging SMTP integration test before production use.

The source overlay includes all new files and seven modified integration files. No extra Erlang package or external billing SaaS is introduced. The PDF worker requires a locally installed `pdflatex` with geometry, fontenc, inputenc, array, longtable, xcolor, fancyhdr and hyperref. Check availability under the **release service user**, not only your interactive shell. The sample uses `pdf_engine = "pdflatex"`; an absolute executable path may also be configured.

Browser and template checks can be repeated independently:

```sh
node --check apps/damage/priv/static/js/billing.js
python tools/check_invoice_ui.py --output /tmp/invoice-ui-check
python tools/check_invoice_template.py --output /tmp/invoice-template-check
```

The browser check needs Python Playwright and `/usr/bin/chromium`. It renders the real component with an in-process mock API, without network navigation. The template check needs `pdflatex`, `pdfinfo` and `pdftotext`; it supplies fixture values in Python, not through the Erlang renderer. These are development-only tools, not production dependencies beyond TeX itself.

## Configuration and first activation

Merge the tuples in `config/enterprise_invoices.config.sample` into the existing `{damage, [...]}` application entry in your release configuration. Do not replace your existing `sys.config`, `node_admins`, SMTP settings or unrelated application configuration. All configuration is tuple/proplist based; JSON and internal records use maps.

The key settings are:

```erlang
{invoice_admins, [<<"ak_REPLACE_WITH_AN_EXISTING_INVOICE_ADMIN_ACCOUNT">>]},
{enterprise_invoices, [
    {enabled, true},
    {auto_send, false},
    {data_dir, "/var/lib/damage/invoices"},
    {number_prefix, <<"DBDD-ENT">>},
    {clock, node_local},
    {send_hour, 9},
    {max_periods_per_tick, 20},
    {job_timeout_ms, 120000},
    {pdf_engine, "pdflatex"},
    {temp_dir, "/tmp"},
    {seller, [
        {name, <<"DAMAGEBDD">>},
        {abn, <<"REVIEW_SELLER_ABN">>},
        {email, <<"billing@damagebdd.com">>},
        {address, <<"REVIEW_SELLER_ADDRESS">>},
        {gst_registered, false},
        {payment_instructions, <<>>}
    ]},
    {payment_profiles, []}
]}.
```

Use actual verified account addresses, seller details and payment instructions, not the explanatory placeholders above. Empty default payment instructions or a missing selected payment profile prevent issuance. Invoice admins select node-configured payment profiles; canonical seller/payment configuration is not editable through the billing API. Free-text descriptions and notes remain editable by billing administrators, so those administrators must be trusted with invoice content.

Choose a fresh number namespace and keep it stable. `DBDD-ENT-000001` is the initial number in the supplied configuration. Existing historic invoice or quotation numbers are **not** imported. Do not change the prefix to a historic series and assume its previous sequence has been migrated.

Use exactly **one billing authority** for a given invoice series. Other Damage nodes can retain the default disabled setting. This implementation has no distributed lock or cross-node consensus.

`clock = node_local` uses the billing node's operating-system time zone. For Sydney billing, configure the release's `TZ=Australia/Sydney` environment, or set the operating-system zone appropriately. Check the date and hour in the release shell:

```erlang
damage_invoice_backend:billing_clock().
```

Use `{clock, utc}` for UTC instead. `send_hour` is the earliest allowed hour in that clock, not a precise cron appointment. A restart, worker backlog or outage can delay execution.

Ensure the release user owns a persistent `data_dir` outside `priv`, the application release directory and public web roots. The directory becomes mode 0700; the DETS file becomes 0600. Do not run the production release as root. A private tmpfs directory is preferable for PDF scratch files.

## Private onboarding data

Real customer terms and recipients are deliberately excluded from the committable source patch. The separate private onboarding archive contains:

```
config/enterprise_invoices/customers.local.json
config/enterprise_invoices/settings.local.config
config/enterprise_invoices/ONBOARDING.local.md
```

The patch adds `config/enterprise_invoices/.gitignore` to exclude local files in that directory. Keep the onboarding archive and its README out of a public repository. The regular source tree includes only a fictitious `enterprise_invoices.seed.example.json`.

Review the private onboarding README, merge verified payment profiles into the billing configuration, then use **Invoices -> Customers -> Import reviewed seed JSON** to import `customers.local.json`. Imports do not overwrite existing IDs, and forcibly disable customers/plans and auto-send. Import is sequential rather than transactional: a validation failure can leave earlier rows imported. Refresh and re-import after correcting the file; existing IDs are skipped.

Complete recipients and legal details, activate each reviewed customer, then choose each plan's agreed commencement date, cadence, amount, tax, scope and payment terms. Do not infer acceptance or commencement from a quotation's date.

Begin with both global and per-plan auto-send off. Use a test recipient you control and review the first draft, issued PDF, email attachment and relay acceptance. Only then enable automatic sending for approved production plans.

## Permissions

| Capability | Node admin | Invoice admin | Ordinary / shared L402 identity |
| --- | --- | --- | --- |
| Customers, plans, drafts, invoice list and PDFs | Yes | Yes | No |
| Approve issuance, email/retry, void and record payments | Yes | Yes | No |
| Grant/revoke managed invoice-admin accounts | Yes | No | No |
| Access other node-admin/wallet functions via this role | Existing node permissions only | No | No |

Invoice admins have access to **all commercial billing records on this billing node**. This is not a customer-scoped or tenant-scoped role. The role exists in the billing service; it does not elevate the same account inside generic BDD execution or wallet APIs.

Node admins can delegate the role in the Invoice admins pane. Grants in the `invoice_admins` configuration are shown as configuration-managed and must be revoked in that configuration. Managed grants are encrypted in the billing database. The configured shared `l402_account` is denied even when accidentally included in an invoice-admin list.

Every billing endpoint requires an explicit existing Bearer token. Cookie-only, query-token, Nostr-only and L402 authentication are not accepted. Browser requests use the existing TokenManager, omit cookies and discard responses after authentication changes. Billing data is not stored in browser local storage. The API enforces access independently of hidden UI controls.

## Billing calendar, amounts and snapshots

Monthly recurrence preserves the original anchor: January 31 -> February 28/29 -> March 31. Fortnightly means exactly 14 calendar days, not twice a month. Service periods are inclusive in the PDF; the next service date minus one day is the previous period's end.

Creating a draft atomically advances the plan cursor. Repeating generation for the same `(plan_id, period_start)` returns the existing invoice, including after a normal service restart. Concurrent requests are serialized. Updates require the current revision to avoid silently overwriting another admin's edits.

Past missed periods are generated as reviewable drafts, oldest first. At most one period per due plan and `max_periods_per_tick` plans are processed per minute. Only a newly generated period starting **today** qualifies for automatic issuance, and it requires both global `auto_send` and the plan's `auto_send` flag. An operator who enables a plan after its commencement date must review the catch-up drafts instead of expecting automatic historic emails.

Current global/plan/customer opt-outs are rechecked for automatic queued mail, including immediately before SMTP begins. Turning off auto-send can hold an automatic email in `queued`; re-enable the approved settings to release it, or void the invoice when appropriate. Disabling the entire feature blocks all new work. Neither setting can recall a message already handed to SMTP.

Quantities are positive whole numbers. Unit prices and line discounts are nonnegative integer minor units; tax is integer basis points. Discounts cannot exceed the line's gross amount. Tax is calculated on each discounted line, rounded half-up, and summed. This initial version supports two-decimal AUD, USD, EUR and GBP; it does not implement fractional quantities, tax-inclusive pricing, tax-jurisdiction decisions or currency conversion.

The supplied zero-tax examples do not establish the seller's GST registration. Confirm `gst_registered` and each line's tax treatment before issuing. The renderer uses `INVOICE` when registration is false, and `TAX INVOICE` when true. Nonzero tax cannot be issued while registration is false. This is an operational configuration guard, not a tax-compliance determination.

Customer details and commercial line items are copied into a draft. Later edits to customers or plans do not silently change existing invoice snapshots. Approval freezes seller/payment instructions, issue date, due date, number and totals. The resulting PDF is stored encrypted with a SHA-256 digest and reused for downloads and email, not regenerated from current customer data.

Draft edits cover line items, terms and notes. Customer/cadence/commencement cannot be changed on a plan after its first period has been generated. For a corrected customer snapshot or replacement of a voided period, create a deliberately named replacement plan with the correct start date, leave the old plan paused and record the reason. This version does not implement a dedicated replacement/credit-note workflow.

## Invoice and email lifecycle

```
draft -> issuing -> issued -> paid
                 -> issue_failed -> issuing (same reserved number)

draft / issue_failed / issued -> void
```

No hard-delete API is provided. Voiding retains the number, PDF where present, amounts and audit history. Paid invoices cannot be voided through this interface; refunds and credit notes need a separate accounting workflow. Manual generation may be used in advance of a future service period. A paused plan can therefore also serve as an operator-controlled, one-off drafting source.

Email state is separate from invoice state:

```
not_sent -> queued -> sending -> sent
                   -> failed     (preparation failed before SMTP)
                             -> unknown (SMTP may have accepted)
```

Only an issued invoice can be emailed. PDF decryption, integrity checking, MIME creation and credential preparation happen first. Immediately before SMTP, the server persists `sending`; only a successful durable write permits the send call. The worker uses the synchronous `send_blocking/2` interface and treats a nonempty binary relay receipt as acceptance. Existing `damage_utils:send_email/4` retains its previous asynchronous behaviour; new `/5` and prepare/send-prepared helpers support the outbox.

`sent` means **SMTP relay accepted**, not guaranteed inbox delivery or customer acknowledgement. Failed SMTP calls, timeouts and crashes after the start boundary become `unknown`, conservatively. A restart converts persisted `sending` to `unknown`; it does not automatically resend it. Preparation failures become `failed`. Both require an explicit admin action to retry. Retrying `sent` or `unknown` requires `confirm_resend: true` and a UI confirmation.

Each delivery generation has a stable Message-ID. It helps correlate relay logs; it is not an exactly-once delivery guarantee. A fresh explicit resend uses a new generation. Relay retries are disabled in the new adapter. SMTP receives a PDF attachment plus plain-text and HTML alternatives. Dynamic HTML is escaped, email headers reject line breaks, filenames are constrained, and the TeX worker uses escaped fields and an argument vector with shell escape disabled.

Existing SMTP host, hostname, port, user, from-address and `smtp_password` secret are reused. The adapter requires authenticated STARTTLS with certificate and hostname verification. Configure an appropriate relay endpoint; implicit TLS/SMTPS and unauthenticated mail-catcher modes are not added by this patch. Use your staging relay to test the actual gen_smtp version pinned by the full monorepo.

## Payment recording and exclusions

Record payment only after independently confirming the receipt. The UI requires a date, transaction/reference and verification note. This action updates accounts-receivable state; it does not debit a wallet, change the NWC ledger, credit DAMAGE tokens or make a bank/Bitcoin transaction.

Static bank/Bitcoin instructions are supported. Automatic AUD-to-BTC conversion, fresh BOLT11 generation, payment webhooks, blockchain/bank reconciliation, partial payments, automatic reminders, accounting exports and credit notes are outside this implementation. Existing Lightning functionality remains separate and unchanged.

## Private API

Responses use `{ "status": "ok", "data": ... }`; errors use a message and an appropriate HTTP status. All paths below are under `/api/billing`.

| Method / path | Request / purpose |
| --- | --- |
| GET `/session` | Server-derived role and current operational capabilities. |
| GET `/customers`, `/plans` | Private lists. |
| POST `/customers`, `/plans` | Create by `id`; an existing ID requires its revision. |
| PUT `/customers/:id`, `/plans/:id` | Update with current `revision`; body ID must match URL. |
| POST `/plans/:id/generate` | `{ "period_start": "YYYY-MM-DD" }`; idempotent draft for next period. |
| GET `/invoices` | `status`, `customer_id`, `limit` (1-100), `offset` filters. |
| GET `/invoices/:id` | Full invoice snapshot, delivery state and audit. |
| PUT `/invoices/:id` | Draft-only revision-checked items, notes or terms. |
| POST `/invoices/:id/issue` | `{ "revision": N }`; returns 202, poll for PDF result. |
| POST `/invoices/:id/send` | `{ "revision": N, "confirm_resend": false }`; returns 202. |
| GET `/invoices/:id/pdf` | Authenticated stored PDF download. |
| POST `/invoices/:id/paid` | Revision, `paid_on`, `payment_reference`, `note`. |
| POST `/invoices/:id/void` | Revision and required `note`. |
| GET / POST `/admins` | Node-admin only; grant/revoke with `account` and boolean `enabled`. |

The API body limit is 256 KiB; unknown/read-only JSON fields are rejected and input keys are not converted to new Erlang atoms. Validation returns 400, stale/invalid transitions 409, missing authentication 401, denied roles 403, missing resources 404 and unavailable/disabled/locked billing 503. PDF/state replies are private and no-store. No public invoice URL or bearer token in a URL is generated.

## Persistence, recovery and operating limits

The service uses one encrypted root snapshot for customers, plans, numbering, invoice states, managed grants and audits, plus encrypted PDF objects in DETS. Mutations are synchronized before acknowledgement. The service serializes state transitions; one monitored, linked worker handles PDF or email effects so slow external work does not execute inside ordinary state callbacks. Worker deadlines are bounded; PDF generation has its own 45-second deadline.

A normal service restart restores the cursor and reserved sequence and resumes safe work. Store write/read/decryption errors do not silently discard records. Existing malformed or unclean stores are not automatically repaired or recreated. A missing database is treated as a new installation: do not point an existing invoice series at an empty directory or recreate lost state by re-importing customers. Restore the authoritative backup and reconcile uncertain mail first.

Before backup, turn off automatic sending, drain or reconcile the worker/outbox, stop the billing child (or release) so DETS is closed, and back up the database and its node-key recovery material using your existing secure key-backup procedures. Preserve permissions and the node identity: invoices encrypted under one identity do not become readable under an unrelated new node key. Keep backup keys separate from the data backup. A live file copy is not a documented consistent-backup mechanism here.

The database and API audit trails are private operational records, not independent tamper-evident proofs. A trusted node operator with the encryption keys can alter local data outside these APIs. Customer data and PDFs are never published to IPFS or chain by this service.

This is intentionally a small-enterprise, single-node receivables module. Root-snapshot persistence and customer/plan listings grow with the dataset. There is no database pagination for those lists, active/active cluster support, retention/archival service or automatic recovery from arbitrary storage corruption. Monitor store size, disk space, worker failures and SMTP unknown outcomes; migrate storage before high-volume use.

## Staging acceptance

Run the supplied EUnit modules first. On an isolated staging node, validate real signed admin and ordinary-user tokens against Cowboy; verify 401/403 on invoice details and PDFs; confirm that invoice admins cannot grant roles; then generate a draft twice and compare IDs, restart and compare again. Issue a PDF, change the source customer, and verify the issued document remains unchanged. Send to your own test mailbox, inspect its attachment and MIME alternatives, then simulate relay failure/restart and confirm the UI requires explicit review before retrying.

`apps/damage/test/features/enterprise_invoice_auth.feature` contains valid existing HTTP steps for the unauthenticated boundary. It makes no invoice or email writes and contains no real token. Adjust its staging URL. Do not put production invoice data or real billing credentials into public BDD reports.
