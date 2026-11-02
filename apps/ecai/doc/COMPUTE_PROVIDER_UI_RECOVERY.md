# Compute provider UI: asset and theme recovery

This is a follow-up to `ecai-provider-clickthrough.patch`, not a replacement for
its provider backend. Apply it on top of that patch. No Erlang source, account
settings, credentials, budget policy, dispatch or minting code is changed.

## Failure signature

The reported screen combines the new provider-picker HTML with native-looking
buttons and the text `Generated when connection is saved`. That string was
written by the pre-onboarding controller. The previous patch changed the CSS
and controller without changing their URLs. Browser/proxy caches or stale
static files in a running release can therefore explain the mixed UI.
The screenshot alone cannot distinguish those deployment causes.

Separately, the previous CSS mixed inherited text colours with white background
fallbacks and unrelated theme variables. This could make the panel unreadable
under a dark/shared theme. Refreshing assets alone does not fix that defect.

## Changes

- Both compute asset URLs use `?v=compute-provider-ui-v2`.
- The template, CSS and controller carry the same version marker. The controller
  dismisses a dedicated loading message only after matching all three. Failed
  CSS loading and stale-served CSS/JS leave a visible diagnostic message. This is
  a deployment hint, not a cryptographic integrity or authentication check.
- Compute has paired, component-scoped canvas/surface/text colours, including
  labels, placeholders, disabled controls, code blocks, navigation and cards.
- Dark mode follows the system preference. Explicit `.theme-dark`, `.theme-light`,
  `.force-dark`, `.force-light` or `data-theme="dark"/"light"` on HTML/body take
  precedence. Do not set contradictory explicit theme choices.
- Shared `.view.is-visible` no longer overrides the compute grid and its gaps.
- Provider cards, expandable forms and long identifiers wrap on small screens.
- Global authentication, credential handling and provider consent are unchanged.

## Apply and deploy

From the repository root containing `apps/ecai`:

```sh
PATCH="$HOME/Downloads/ecai-provider-ui-recovery.patch"
git apply --check "$PATCH" && git apply "$PATCH"
node --check apps/ecai/priv/static/js/ecai-compute-settings.js
python3 -m unittest apps/ecai/test/test_compute_dashboard_contract.py
node apps/ecai/test/test_compute_provider_onboarding.js
rebar3 compile
```

Deploy the modified templates and static assets to the running release using
your usual build/deployment procedure. Compilation alone is not evidence that a
separate deployed release now serves those files. Hard-reload `/dashboard#compute`
after deployment. There is no need to delete browser storage, sign out, regenerate
external IDs, or recreate provider connections.

In the browser developer console after opening Compute:

```js
const panel = document.querySelector('[data-panel="compute"]');
console.table({
  template: panel?.dataset.computeUiVersion,
  controller: window.EcaiComputeSettings?.assetVersion,
  stylesheet: panel ? getComputedStyle(panel).getPropertyValue('--compute-ui-version').trim() : null,
  assets: panel?.dataset.computeAssets
});
```

The first three values must be `compute-provider-ui-v2` and `assets` must be
`ready`. This verifies asset agreement, not cloud identity/access.

If they do not match, inspect the Network responses for the versioned CSS/JS
URLs. A 200 response is not sufficient: the response must contain the new
version marker, not an older asset or HTML error/login page. Check reverse-proxy
caching and the running node's actual static directory. From the Erlang shell:

```erlang
code:priv_dir(ecai).
```

Inspect `static/css/ecai-compute-settings.css`,
`static/js/ecai-compute-settings.js` and `templates/ui/dashboard/` under that
returned directory. Do not assume a source checkout and deployed release share
one `priv` directory. Prefer your deployment procedure over overwriting release
files ad hoc.

## Browser regressions

With Python Playwright and Chromium available:

```sh
python3 apps/ecai/test/test_compute_provider_browser.py
```

`ECAI_CHROMIUM` can select a Chromium executable. The suite serves the actual
console shell and bundled styles with the compute controller at their template
URLs, while stubbing shared DamageBDD auth and unrelated dashboard controllers.
All provider API responses are mocked; no cloud endpoint is contacted.

For a browser environment that cannot navigate to a loopback HTTP server:

```sh
python3 apps/ecai/test/test_compute_provider_browser.py --dom-only
```

The offline adapter resolves the template's original URLs using Python against
the fixture server, then supplies the selected response bytes to Chromium as
data resources. It tests DOM behaviour, CSS, URL-version selection and failure
messages, but does not validate browser HTTP caching, headers or transport.

Coverage includes eight combinations of light/dark and 1440/958/390/320-pixel
viewports, explicit theme overrides, deliberately conflicting inherited theme
rules, a >=4.5:1 check on sampled text/control colours, responsive layout,
keyboard provider selection, mocked prepare/save/verify flows, error recovery,
a signed-out write guard, and missing/stale CSS and controller responses.

Validated for this fix: seven contract tests (including the Node smoke test),
standalone Node smoke test, and seven Chromium tests in offline-adapter mode.
Browser HTTP navigation was blocked by the execution environment's policy.
The full DamageBDD auth flow, Cowboy, Erlang compilation/EUnit, real IAM access,
and cloud execution were not tested here. No Erlang code is modified by this fix.
