# Validation record

Prepared against the `latest-damage.tar.gz` uploaded in this conversation on 9 October 2026. The patch is an implementation for review and staging, not a claim of a production deployment.

## Executed successfully

| Check | Result / scope |
| --- | --- |
| JavaScript syntax | `node --check apps/damage/priv/static/js/billing.js` passed. |
| Browser component | 10 Playwright/Chromium checks passed; no browser page errors. The real billing JavaScript, markup and CSS were exercised with an in-process mock API. |
| Desktop and mobile layout | Screenshots inspected at 1440px and 390px; mobile tables scroll within their containers. |
| LaTeX template | Monthly, fortnightly and escaping-test fixtures compiled with pdflatex; all were one page, with no overfull horizontal boxes or remaining template placeholders. |
| PDF appearance | Sample PDFs were rasterized and inspected. These are marked SAMPLE / DO NOT PAY and contain no live payment destination. |
| Python tools | The browser and PDF fixture tools ran successfully. |
| Source hygiene | `git diff --check` passed. New Erlang sources/tests and the config sample received basic delimiter checks. Those are not compiler checks. |

The browser checks cover role-specific navigation, a single authenticated revision-checked send submission, pagination, text-only rendering of hostile-looking customer names, exact-cent/tax input conversion, failed-save button recovery, mobile overflow, logout clearing, and denial of an ordinary account's billing UI. This tests the client against mocked responses, not the actual authorization server.

## Supplied, but not executed here

`damage_invoice_model_tests`, `damage_enterprise_invoices_tests`, `damage_invoice_http_tests` and `damage_mail_tests` cover arithmetic, calendar anchors, fixed periods, role delegation, shared-L402 denial, concurrent/idempotent generation, persistence failures, snapshots, render retries, SMTP acceptance/uncertainty, restart during send, automatic-generation gates, opt-out immediately before SMTP, route boundaries, header injection and MIME shape/round-trip behaviour.

**Erlang compilation and EUnit were not run.** This environment has no Erlang/rebar3 toolchain; attempts to obtain one were unsuccessful. The uploaded archive also lacks the full monorepo's root build/dependency configuration. Basic source checks do not establish that the modules compile against the project's actual OTP and dependency versions.

The PDF fixtures interpolate the real template with Python. They do not execute `damage_invoice_pdf:render/1` or test its Erlang `open_port` behaviour. The browser harness does not boot the entire DamageBDD dashboard, Cowboy, the real token verifier, the DETS encryption path or gen_smtp.

## Required before production

Run compilation and the four EUnit modules in the full monorepo. Then exercise the complete Cowboy authentication boundary, encrypted persistence/restart, Erlang PDF worker, actual pinned MIME/SMTP library and delivery to your own test mailbox on an isolated staging node. Test SMTP interruption and confirm that uncertain messages are not automatically resent. Keep production automatic sending disabled until these checks pass.

No live customer invoice was issued, no payment was requested or made, and no real email was sent during this work. Demonstration data and mocked side effects were used for the executable checks.
