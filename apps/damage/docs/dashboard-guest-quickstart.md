# Anonymous dashboard: Quickstart entry point

`/` now renders an onboarding landing for requests without authenticated account state.
The guest view displays an HTML form (`GET /try?url=...`) and does **not** send a
request to a customer's target. The `/try` page prefills the URL and posts it
to the existing deterministic `/api/quickstart/generate` endpoint to build a
DamageBDD Gherkin proposal. Network execution requires a **separate click**.

The sign-in and create-account buttons open the existing dashboard auth modal.
The anonymous auth modal is **not** automatically opened; authenticated users
still get their original workspace and a new Quickstart link in the sidebar.

## Enable the existing Quickstart API

The existing route is opt-in. Set `quickstart_enabled` to `true` in the `damage`
application's tuple-valued `sys.config` list, as documented by the original
quickstart onboarding feature. With `quickstart_trial_enabled = false`, users
can generate and copy/download tests but **cannot** perform free execution.
Free executions require operator allowlisted exact HTTPS targets, a quota secret,
and the trial settings detailed in `docs/QUICKSTART_ONBOARDING.md`. Scheduled
runs require a signed-in account and normal execution credits.

Only public HTTPS URLs without query parameters, URL credentials or unusual
ports are supported in the current MVP. The unauthenticated dashboard does
not claim general unauthenticated scanning, unlimited free runs, or free
scheduling. The guest form passes the target URL in a query string; customers
should not submit credentials or confidential path parameters.

## Test

```sh
node --test apps/damage/test/scripts/dashboard_guest.test.mjs \
  apps/damage/test/scripts/quickstart_ui.test.mjs \
  apps/damage/test/scripts/quickstart_prefill.test.mjs
```

For the public site, add the Quickstart CTA near the hero in `org/index.org`
and publish the linked `org/quickstart.org` guide. The site source is separate
from the supplied `apps/damage` archive.
