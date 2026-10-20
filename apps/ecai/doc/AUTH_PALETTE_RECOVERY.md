# Login dialog colour recovery

## Scope

The ECAI dashboard loads shared DamageBDD `auth.css`, ECAI's `ecai-auth.css`,
and a later generated `/api/themes/css?app=ecai` stylesheet. The old ECAI
rules pinned a white auth palette and input background, but did not set
input text fill, caret, autofill paint or native colour scheme as a unit.
The reported screenshot shows pale input text over grey fields inside a
light dialog. The exact live rule responsible for the grey paint is not
established: the current shared auth stylesheet and node theme manifest
were not included in the uploaded ECAI archive.

The fix modifies only two runtime files:

- `priv/static/css/ecai-auth.css`: complete, modal-scoped light/dark palettes.
- `priv/templates/ui/dashboard/ecai_console.mustache`: version the existing
  auth stylesheet URL as `?v=auth-colours-v1` (one line).

The patch also adds this note and two style-test files. No auth controllers,
HTTP handlers, sessions, stored credentials, provider connections, branding
assets, compute settings or global theme manifests are changed.

## Behaviour

The default light palette uses navy text on white fields. The dark palette
uses pale text on navy surfaces. Primary actions keep white text on indigo.
Labels, helper text, links, tabs, wallet controls, error/success messages and
disabled controls are explicitly paired with their own backgrounds.

The dialog follows the OS light/dark preference. Explicit `data-theme="light"`
or `data-theme="dark"`, `.theme-light`/`.theme-dark`, or `.force-light`/
`.force-dark` on HTML/body override that preference, matching the selectors
already used by the compute UI recovery. Avoid contradictory theme markers.
No JavaScript detector, new theme preference or session storage is added.

The shared `--auth-*` variables are aliased locally to `--ecai-auth-*` tokens.
Targeted important paint declarations protect the modal from later important
global input/button rules. They do not repaint other forms. Autofill keeps
an inset field surface plus matching text-fill and caret colours; its focus
outline remains separate. Password types and autocomplete attributes are
unchanged. System forced-colour mode keeps system colours rather than
opting users out of high contrast. The rounded container shape is preserved.

Autofill reference: https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Selectors/:autofill
Text-fill reference: https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/-webkit-text-fill-color

## Apply and deploy

Apply the supplied patch from the DamageBDD repository root. It is a new,
independent auth fix; do not reapply the earlier compute patches.

```sh
git apply --check ~/Downloads/ecai-login-colours.patch &&
git apply ~/Downloads/ecai-login-colours.patch &&
python3 -m unittest apps/ecai/test/test_auth_palette.py
```

Deploy the updated `priv` files using the node's usual release process, then
hard-refresh `/dashboard`. Do not clear session/local storage or recreate
accounts. Updating source files is not sufficient when the running release
serves another copy of `priv`; inspect `code:priv_dir(ecai).` in Erlang.

With the login modal present, this browser-console check must return
`"auth-colours-v1"`:

```js
getComputedStyle(document.getElementById('login-modal'))
  .getPropertyValue('--ecai-auth-ui-version').trim()
```

The auth stylesheet request should contain `?v=auth-colours-v1`. Query-string
versioning only works when the node serves the updated CSS and template.

## Validation and limits

The five dependency-free unit tests check version alignment, palette
completeness, text contrast, field/focus boundaries, autofill rules and
isolation from global text tokens. Text pairs target at least 4.5:1;
field/focus boundaries target at least 3:1. These are focused colour checks,
not a claim of complete accessibility conformance.

The Chromium test deliberately loads conflicting important global rules
AFTER the production ECAI override. It checks widths of 1440, 772, 390 and
320 pixels in light/dark mode, explicit HTML/body theme choices, live OS
preference changes, editable/disabled controls, error colours, scoped paint,
and forced-colour behaviour. Autofill uses a DevTools-forced `:autofill`
pseudo-state on the email and password fields, including focus outlines;
it does not invoke a real browser password manager.

In a complete DamageBDD checkout, use the actual shared auth CSS/template:

```sh
python3 apps/ecai/test/test_auth_palette.py --browser
```

Python Playwright and Chromium are required for the browser runner. The
`CHROMIUM` environment variable can select an installed executable; otherwise
it uses `chromium` on PATH or Playwright's installed Chromium.

For the ECAI-only archive, explicitly choose the labelled contract fixture:

```sh
python3 apps/ecai/test/test_auth_palette.py --browser --fixture-only
```

The supplied screenshots and local browser validation use this fixture-only
mode: five unit tests and eighteen browser groups passed. The fixture is a
small style contract, not the actual DamageBDD template. Neither mode runs
auth controllers; neither verifies login, signup email delivery, wallet
proofs, cookies, real password-manager autofill or the live node's generated
theme stylesheet. Run the existing full dashboard-auth suite separately in
the complete checkout for those integration boundaries.
