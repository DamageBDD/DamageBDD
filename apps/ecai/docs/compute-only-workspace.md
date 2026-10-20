# Compute-only workspace

## Scope

The Compute page now owns cloud provider setup, compute budgets, estimates and
reservations. Its sidebar entry, breadcrumb, page title and Index jobs cross-link
no longer describe an NFT workspace. Providers, Budgets and Reservations are real
tab panels with keyboard navigation, not scroll shortcuts.

NFT review buttons, copies and artifact metadata remain on individual index jobs.
Account-wide enablement, recipient, monthly fee allowance and recent request
history live in the expandable **Mint preferences & review requests** panel within
Index jobs. The existing job form's **Mint preferences** button opens that panel.
There is no second mint-submission form on Compute.

## Data and authorization

No records, connection settings, reservations, artifact hashes or review requests
are deleted or migrated. The existing DETS layout and mint APIs remain intact.
The account snapshot and legacy combined policy API remain available for existing
clients; the URL prefix is retained for compatibility, not as a UI placement rule.

Two strictly scoped POST operations use the existing managed-account, explicit
bearer checks. Cookies or wallet-only sessions do not authorize these mutations.

- `/ecai/compute/budget`: exactly `remote_enabled`, `monthly_cents`, `per_job_cents`.
- `/ecai/compute/mint-policy`: exactly `enabled`, `recipient`, `chain`, `monthly_cents`.
  This endpoint's `monthly_cents` updates only the mint fee allowance.

The gen_server merges each update with the latest stored other policy domain
inside one serialized operation, then runs the existing validation, outstanding
reservation floors and durable write. A stale Compute browser cannot echo an old
mint policy back into the store through the new budget endpoint. The inverse is
also true. Concurrent writes within the same policy domain retain last-write
semantics; the legacy full-policy endpoint still replaces both domains.

No fallback to the combined-policy endpoint is used when an old server does not
support the new routes. A failed save must remain an error, not reset the other
workspace's settings.

## UX adjustments included

- Explicit setup/reservations-only notice; no remote execution claim.
- A node-operator prerequisite notice when the AWS coordinator role is missing.
  An external ID may still be prepared, but a safe trust policy requires the
  actual coordinator role. Provider verification remains a separate check.
- Budgets can be viewed/configured before verification. This does not relax the
  server checks for reserving compute.
- “Estimate reservation” replaces “Estimate maximum charge”. Reserved allowance
  is not a reconciled provider invoice or a guaranteed cloud spending cap.
- Local provider selectors use chevrons; external console links retain arrows.
- Mint preferences load only when opened, preserve unsaved edits on refresh,
  clear on identity change, reject late previous-account responses and render
  metadata as text, not HTML.
- Asset versions are updated together for Compute, and new mint-settings assets
  are versioned. Unrelated console features and theme files are not replaced.

## Applying

The reference patch is based on the supplied `latest-ecai.tar.gz`, the later
uploaded console template, and the click-through, UI recovery, login palette and
index-mint patches supplied in this conversation. The running checkout may also
contain newer unrelated changes not present in the archive.

Use the accompanying `make_ecai_compute_only_patch.py` for that case. It reads
current files and generates a local patch without editing or staging the checkout:

```bash
python3 "$HOME/Downloads/make_ecai_compute_only_patch.py" \
  --root . --output /tmp/ecai-compute-only.local.patch

git apply --check /tmp/ecai-compute-only.local.patch &&
git apply /tmp/ecai-compute-only.local.patch
```

The generator preserves unrelated text, including longer asset versions and
additional VIEW_NAMES entries. It stops before writing a patch if expected code
anchors are missing or ambiguous. It does not use fuzzy replacement, replace
whole runtime files, reset Git, stage changes or run cloud operations. Do not
reapply the older patches.

Deploy the updated Erlang modules, dashboard templates and static assets as one
release. Reload the Cowboy router or restart through the normal release workflow
because two routes were added. Old processes that have not loaded the new
`handle_call` clauses cannot accept the new policy messages. Merely refreshing
the browser or compiling without loading code does not update the running node.
Then hard-refresh `/dashboard#compute`. No browser-storage reset is needed.

## Validation

```bash
python3 apps/ecai/test/test_compute_only.py
python3 apps/ecai/test/test_compute_dashboard_contract.py
node --check apps/ecai/priv/static/js/ecai-compute-settings.js
node --check apps/ecai/priv/static/js/ecai-console.js
node --check apps/ecai/priv/static/js/ecai-index-mint-settings.js
python3 apps/ecai/test/test_compute_provider_browser.py
python3 apps/ecai/test/test_index_mint_settings_browser.py
rebar3 compile
rebar3 eunit --module ecai_compute_policy_scope_tests
rebar3 eunit --module ecai_compute_settings_tests
```

In the preparation environment, 12 source/contract tests (including the Node
provider smoke test), 9 Compute Chromium cases and 6 Index mint-settings Chromium
cases passed. Layout coverage includes light/dark and mobile widths down to 320px.
Compute browser tests used their `--dom-only` offline URL adapter; the mint tests
use real component markup/CSS/controller with a test TokenManager and mocked fetch.
Neither suite proves live cloud, Cowboy, authentication or blockchain integration.
Erlang compilation and EUnit were not run here because the compiler was unavailable.
The new EUnit tests cover policy-domain preservation, foreign field rejection,
mint reservation floors and disabled mint defaults for new compute accounts.

No on-chain transaction is submitted by these settings or review controls.
