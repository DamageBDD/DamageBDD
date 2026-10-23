# DamageBDD Browser Recorder — current WebDriver integration

This integration is based on `latest-damage.tar.gz` supplied in this conversation.
The archive contains `apps/damage/` and the v0.1 recorder module, but no monorepo
root `rebar.config`, `rebar.lock`, other umbrella applications or dependencies.

## Upgrade

From the DamageBDD monorepo root, extract `damagebdd-recorder-latest-update.zip`.
The update contains `extensions/damagebdd-recorder/` and a backend patch. It does
not contain a root README, root configuration, or copies of unrelated applications.
Extraction updates the recorder extension; applying the patch changes the backend.

```sh
unzip -o /path/to/damagebdd-recorder-latest-update.zip -d .
git apply --check patches/0002-browser-recorder-current-webdriver.patch
git apply patches/0002-browser-recorder-current-webdriver.patch
rebar3 compile
rebar3 eunit --module=steps_browser_recorder_tests
node --test extensions/damagebdd-recorder/tests/*.test.mjs
```

Do not apply `patches/0001-wire-browser-recorder-steps.patch` from v0.1. Current
`damage_utils:loaded_steps/0` discovers `steps_*.beam` and returns module atoms.
`damage:step_modules_for_context/1` then filters those modules through the role
policy. Do not prepend a module, replace that filtering function, or convert the
module list to strings. No change to `damage.erl` or `damage_utils.erl` is needed.

The patch targets the uploaded backend, including the already-present v0.1
`steps_browser_recorder.erl`. `git apply --check` must succeed before application.
If it fails, leave your existing changes intact; do not use `--reject` or force
an overwrite. The patch is not meant to be applied twice.

## Configure replay

Recording and exporting remain local and do not require a DamageBDD login.
**Live replay requires `node_admin`**, matching the existing WebDriver subsystem.
Role membership comes from the node's configured `node_admins` and authenticated
account, not a field added to a feature's context.

Prefer your existing `{webdriver, [...]}` settings, including managed
ChromeDriver/Appium profiles. An external Selenium example is in
`apps/damage/priv/config/browser-recorder.sys.config.example`.
All configuration objects are Erlang tuples/proplists, not maps.

With a modern profile already configured, no recorder-specific configuration is
needed. The recorder starts that profile and navigates to the captured URL; it
uses ordinary WebDriver browser navigation rather than the dashboard-specific
login/fixture setup operation. The recorded browser is a new automation session,
not the recording user's authenticated browser session. Record the steps needed
to establish a reproducible initial state.

For migration only, explicitly configured `browser_recorder_webdriver_url` and
`browser_recorder_browser` are translated into a native profile when **no** modern
`webdriver` setting is present. Modern settings take precedence. There is no
silent fallback to an automation endpoint when neither has been configured.

A feature can select an existing operator-defined profile before recording steps:

```gherkin
Feature: Recorded signup
  Scenario: A user signs up
    Given I use WebDriver profile "desktop"
    Given I start a recorded browser at "https://example.test/signup"
    When I type into recorded field "#name"
      """
      Alice
      """
    When I click recorded element "#submit"
    Then recorded element "#message" should contain text
      """
      Success
      """
    Then I close the recorded browser
```

The exported vocabulary remains compatible with v0.1. The optional profile step
belongs to `steps_webdriver`; the recorded steps belong to `steps_browser_recorder`.

## Account-scoped private inputs

The extension exports a **name**, never the detected private field's value:

```gherkin
When I type secret "browser_secret_a1b2c3d4" into recorded field "#password"
```

Provision that name in the replaying account's scope using the existing trusted
operator provisioning flow. Where `SecretValue` is already securely obtained:

```erlang
secrets:encrypt_store(
    {account, <<"ak_REPLAYING_ACCOUNT">>},
    <<"browser_secret_a1b2c3d4">>,
    SecretValue
).
```

Replay resolves `secrets:retrieve_decrypt({account, Owner}, Name)` inside the
owned WebDriver client process. The owner is taken from authenticated execution
context; the Gherkin cannot choose it. There is **no node-wide or legacy atom-key
fallback**. Re-provision former v0.1 node-scoped recorder secrets in the account
scope. Plaintext is not returned in context or passed in WebDriver API message
arguments. The website and WebDriver necessarily receive the entered value;
use isolated test accounts and a trusted automation endpoint.

## Lifecycle and replay correctness

The recorder is now a vocabulary adapter over `steps_webdriver` and
`damage_webdriver`, not a second HTTP/WebDriver implementation. It uses the same
owned `webdriver_session` process, operation deadlines, managed service capacity,
protocol-error redaction, lifetime limits, and close operations. Existing
`damage:execute_steps/3` cleanup covers successful scenarios, failures in other
steps, skipped explicit close steps and exceptions. Owner monitoring covers
process exit. A failed remote cleanup remains subject to existing runtime and
server timeout behaviour; cleanup cannot be guaranteed through a network outage.

Text and URL assertions use the native bounded polling loop. Native single
selects are chosen by `select.value`, including an empty value, and duplicate
values are rejected. Checkbox state is idempotent; an already-checked checkbox
is not clicked again. A radio button can be checked but cannot be unchecked by
an independent replay step. Multi-selects are explicitly unsupported.

Clicks are real WebDriver actions. A lost response is a failure, not an excuse to
retry a potentially side-effecting action. This follows the same rule as the
existing native client.

The exporter refuses enabled actions before the first navigation, missing
selectors, unknown enabled actions and unsafe control characters. Such problems
appear as export errors in the editor rather than producing a broken scenario.
Direct manual source editing bypasses the generator's checks; validate manually
edited features before executing them.

## Browser extension

The update retains the existing MV3 Chrome/Firefox extension. Reload it after
upgrading and reload any page with an old recording content script injected.
Chrome: `chrome://extensions` → Developer mode → Load unpacked, selecting
`extensions/damagebdd-recorder`. Firefox: `about:debugging#/runtime/this-firefox`
→ Load Temporary Add-on, selecting the extension's `manifest.json`.
These packages are development builds, not signed store releases.

Open an HTTP(S) test site, start recording from the toolbar, perform the journey,
add a visible-text assertion, then stop and export. Recordings stay in local
extension storage; review ordinary inputs, page titles and URLs for personal
information. Private-field detection is heuristic, not a guarantee that all
sensitive values will be recognised.

One tab is recorded. Popups/new tabs, cross-origin frames, shadow-root controls,
file uploads, rich contenteditable editors, canvas controls and multi-selects are
not supported. Do not mistake an unsupported interaction for replay coverage.

## Validation status

On the supplied source plus this update:

- Original integration patch failure was reproduced.
- Replacement backend patch applies cleanly and passes Git whitespace checks.
- All 16 Node tests pass (13 recorder/vocabulary tests, 3 source-contract checks).
- JavaScript syntax checks pass for the extension's `.js` and `.mjs` files.
- 12 new EUnit cases are included, using local HTTP fixtures plus catalog checks.
  They have **not been executed here**. Erlang, `erlc` and `rebar3` are absent in
  the available environment; the upload also lacks root build files/dependencies.
- A complete `rebar3 compile`, EUnit run, live Selenium/Grid replay, actual
  Chrome/Firefox loading and store-signing validation remain to be run locally.

The Node source-contract checks are not an Erlang compiler, parser integration
run, browser test or proof of a successful live replay.
