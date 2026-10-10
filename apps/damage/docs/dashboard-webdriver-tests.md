# Dashboard BDD: Selenium and Appium

> For DamageBDD-owned dependency installation and driver/fixture supervision,
> use [Managed WebDriver](managed-webdriver.md). The external-server profiles
> below remain supported for independently managed Selenium Grid/Appium servers.
> Managed profiles must not also specify an `endpoint`.


This is an additive change on top of the DamageBDD **sidebar + ECAI composer**
implementation. It does not replace the legacy `steps_webdrv` or
`steps_webdrv_bidi` modules, and does not change dashboard payment or invoice
mutation logic. It also gives the Swap Options partial a distinct
`swap-options-panel` ID: the shell already owns `swap-options-tab`, and the
new strict single-element assertions exposed that duplicate ID.

## What runs

The eight `.feature` files in
`test/damage_dashboard_webdriver_SUITE_data/` use native DamageBDD `step/6`
clauses in `steps_webdriver.erl`. `damage_webdriver.erl` implements the W3C
WebDriver HTTP commands used by the tests. There is no Behave/Cucumber Python
runner and no Selenium/Appium Python client dependency.

`damage_dashboard_webdriver_SUITE` is a local Common Test harness: it parses
these files with the real `egherkin` dependency, tokenizes steps with
`damage_step_tokenizer`, and invokes the same native step module. It deliberately
does **not** call Damage's paid execution/report-publication orchestration.
Every scenario owns a fresh session, stops on its first failed step, and attempts
cleanup even when an assertion or step lookup fails. Common Test reports one test
case per feature file, with individual scenario outcomes in the case log.

| Feature / selection name | Scenarios | Coverage |
| --- | ---: | --- |
| `navigation` | 8 | Initial workspace, seven ordinary panels, active links/fragments, editor/prompt preservation, Back/Forward, deep links, context expansion, step search/insertion |
| `desktop` | 4 | Collapse preference across reload, keyboard navigation, Escape focus restoration, desktop/mobile resize cleanup |
| `mobile` | 4 | Real device layout breakpoint, inert background/sidebar, drawer modal state, selection focus and touch backdrop dismissal |
| `composer_fixture` | 13 | Examples, draft generation/review/undo, invalid/incomplete drafts, cancellation, 401/503, unavailable model, markup rendered as text, stale validation, simulated run output, deferred/revoked billing navigation |
| `composer_keyboard` | 2 | Duplicate generation and Run keyboard shortcuts while a request is held in flight |
| `live_auth` | 3 | Unauthenticated shell absence, invalid login feedback, real credentials login and logout |
| `live_generation` | 1 | Actual configured ECAI generation, separate review, preserved editor, no Run action |
| `live_billing` | 1 | Actual authorised billing panel and invoice/customer pane switching without mutations |

There are **36 scenarios** in total. Desktop fixture selection runs 27; mobile
fixture selection runs 25. (Desktop and mobile selections share scenarios.)
The live profile defaults to 15 scenarios: navigation, desktop, and live auth.
Live model generation and live billing are opt-in. A repository-wide `rebar3 ct`
without a `webdriver` profile reports this external-service suite as skipped; it
does not unexpectedly require a browser service. A supplied but invalid profile,
unknown selected case, missing driver, or failed assertion is a failure, not a
pass or silent fallback.

## First run: local ChromeDriver and deterministic UI fixtures

Run from the complete umbrella repository, with its normal dependencies and
Erlang/rebar3 toolchain installed:

```sh
rebar3 compile
rebar3 eunit --module=damage_webdriver_tests
```

The unit tests include an actual loopback HTTP server to inspect the client's W3C
requests, distinct sessions, ownership checks, cleanup, redacted errors,
configuration validation and dry-run behaviour. The feature-contract test checks
all eight files against BEAM-derived signatures using the real Gherkin parser.
They do not need ChromeDriver, Appium, a funded account, or a running node.

In one terminal, serve the fixture:

```sh
python3 apps/damage/test/scripts/dashboard_webdriver_fixture.py
```

In another, start a **provisioned ChromeDriver matching your installed Chrome or
Chromium**:

```sh
chromedriver --port=9515
```

Run the native BDD suite in a third terminal:

```sh
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/selenium-fixture.config
```

For responsive desktop-browser emulation, use
`selenium-mobile-fixture.config` instead. This profile is explicitly **not** an
Appium or physical-device run.

The fixture serves production templates, the actual navigation and composer
controllers, and the execution-submit guard extracted by the existing browser
fixture. Auth, wallet, reports, schedules, billing services and model responses
are **simulated**, not a second OTP node. It does not load every production
integration from `main.js`. Its HTTP responses are no-store; its content security
policy disallows real network calls and form submissions. The default binding is
loopback; `/health` identifies it as a fixture.

In-flight scenarios explicitly hold and release fixture responses. They do not
race a fixed delay on a slow device. Cancellation remains responsive while a
response is held, and an unreleased gate eventually fails. `fixture_idle` waits
for outstanding mocked fetches; Run assertions separately wait for completion of
the simulated execution. The fixture gate and service-control steps refuse live
profiles.

## Selenium Grid

The same profile can target a Grid without changing feature files:

```sh
DAMAGE_WEBDRIVER_URL='http://127.0.0.1:4444' \
DAMAGE_DASHBOARD_URL='http://fixture-host-reachable-from-grid:8765' \
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/selenium-fixture.config
```

Set the actual reachable fixture hostname. Bind the fixture to a trusted network
interface when required. A Grid browser's `localhost` is not necessarily the
Common Test host. An explicitly configured prefix such as `/wd/hub` is preserved;
it is not silently added. Do not expose an unauthenticated automation server to
the Internet. URLs containing embedded credentials, query tokens or fragments
are rejected; use a trusted network or secured deployment appropriate to your
Grid instead.

## Appium: Android Chrome

Install Appium and the platform prerequisites on the automation host. Install and
check the Android driver before starting the Appium server:

```sh
appium driver install uiautomator2
appium driver doctor uiautomator2
appium --address 127.0.0.1 --port 4723
```

Use a dedicated Android emulator/device with Chrome installed and a compatible,
provisioned ChromeDriver. Select its exact `appium:udid` in a private copy of the
config when multiple devices are attached. Do not enable relaxed security or
automatic executable downloads merely to run these tests.

Keep the fixture running and execute:

```sh
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/appium-android-fixture.config
```

The supplied Android-emulator target is `http://10.0.2.2:8765`. For a physical
USB device, one option is `adb reverse tcp:8765 tcp:8765` with
`DAMAGE_DASHBOARD_URL=http://127.0.0.1:8765`; remove that forwarding after testing.
Alternatively, bind the fixture to an explicitly trusted LAN interface and use
its reachable address. With a remote Appium server, configure the target from
the device's point of view, not the test VM's.

This is **mobile web** coverage using CSS selectors. It does not install an APK,
switch to a native WebView, automate wallet-app handoff, or claim native Android
application coverage. The profile requires a viewport at or below the
900 CSS-pixel mobile breakpoint; the mobile feature asserts this rather than
silently resizing a device.

## Appium: iOS Safari

Use an Appium/XCUITest host on macOS with the required Xcode tooling, a selected
iPhone simulator/device and its normal Safari automation setup. Before starting
Appium, install the driver:

```sh
appium driver install xcuitest
```

Copy `appium-ios-fixture.config` outside the repository and replace
`REPLACE_WITH_INSTALLED_IPHONE_SIMULATOR` with the installed device name, plus its
exact `appium:udid` and `appium:platformVersion` as needed. Start the fixture on a
host reachable from Safari and the Appium server on port 4723, then run:

```sh
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=/path/to/private-appium-ios.config
```

The configuration uses `browserName=Safari` and
`appium:automationName=XCUITest`. It is a mobile Safari suite, not native iOS UI
coverage. Desktop keyboard/resize scenarios are excluded from both Appium
fixture profiles. Input, focus, alerts and touch behaviour still require
verification on your chosen OS/browser/driver versions.

## Live staging-node tests

Use a **dedicated test account and browser/device**, not a production wallet.
Each new scenario clears cookies accessible at the target URL and the target
origin's local/session storage before loading the page again. This prevents a
retained Appium browser login from making auth tests pass without authentication.
It intentionally signs the test browser out of previous sessions.

Supply credentials via environment variables or your CI secret store. Do not put
passwords, access tokens or seed phrases in feature files or commit config copies.
For example, in Bash:

```bash
read -r -p 'Test account email: ' DAMAGE_UI_USERNAME
read -r -s -p 'Test account password: ' DAMAGE_UI_PASSWORD
printf '\n'
export DAMAGE_UI_USERNAME DAMAGE_UI_PASSWORD

DAMAGE_DASHBOARD_URL='http://127.0.0.1:8080' \
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/selenium-live.config

unset DAMAGE_UI_USERNAME DAMAGE_UI_PASSWORD
```

The live profile uses the real login form. No localStorage authentication bypass,
forged role flag, model-response mock, or server reset endpoint is installed.
The account needs access to the dashboard and its step catalog. Backend outages
may legitimately fail live navigation/step-library checks.

For live mobile runs, copy an Appium profile, set `{fixture, false}`, add the same
`credentials` proplist used by `selenium-live.config`, and select
`[navigation, mobile, live_auth]`. The semantic sign-out step opens the mobile
drawer before clicking its footer action. Do not keep `composer_fixture` in a
live profile: the harness rejects it.

Enable model generation deliberately by adding `live_generation` to
`webdriver_suites` in a private config copy. It invokes your configured ECAI
service and consumes inference resources. Add `live_billing` only when the actual
logged-in account is entitled to that panel. **No live test clicks Run, pays an
invoice, sends mail, creates a schedule, transfers funds, or signs a wallet
transaction.** UI visibility is not proof of backend authorization; retain the
server authorization tests separately.

## Native DamageBDD use and configuration

All profiles use tuples/proplists, including nested capability objects. JSON
string capability values are binaries, e.g. `<<"Chrome">>`. The Common Test
config has separate top-level `{webdriver, [...]}` and `{webdriver_suites, [...]}`
terms; it is not a `sys.config` application list.

Outside CT, put the profile under the existing `damage` application's
`{webdriver, [...]}` setting, or supply it as a Config override to the ordinary
Damage runner. `webdriver_suites` is specific to CT. Each feature can also be
submitted to the native runner after deployment, but **that runner's normal
execution charges, authorization and report publication rules still apply**.
The local CT harness avoids those surrounding operations; it does not disable
them in Damage.

The new step module is annotated `-damage_roles([node_admin]).` and repeats the
admin check at runtime because it can access operator-configured credentials and
an automation service. CT temporarily authorizes one synthetic local principal
in its dedicated VM solely to dispatch these steps; it does not grant that role
to the browser account or change the remote node. The harness refuses to run
inside an already-started Damage application.

The module exposes exact, non-overlapping `WebDriver` phrases; its concrete
`step_dry/6` clauses perform no browser actions. `damage_webdriver` uses binary-key
JSON decoding, peer-verified HTTPS, bounded command/assertion timeouts and zero
implicit waits. Each process owns its remote session. Clients delete it on close,
attempt cleanup on step failure and owner exit, and have idle/lifetime limits.
A lifetime expiry is processed after any current bounded operation. Configure
remote Grid/Appium session timeouts too: loss of network connectivity, process
kill during remote session creation, or a dead automation server can prevent a
local DELETE from reaching the remote session.

The patch adds OTP `inets` to `damage.app.src` so `httpc` is included in releases.
It adds no third-party Erlang dependency and leaves existing WebDriver modules
unchanged.

## Diagnostics and boundaries

Failures include the feature/scenario, line or operation, and a sanitised error
category. Missing and ambiguous elements do not count as successful hidden-state
assertions. Click commands are never retried, because an uncertain response must
not cause a second submission. Tests fail rather than silently passing when a
capability, profile, credential or step is unavailable.

Entered credential values and remote error messages are not placed in the Damage
context or normal test failure output. Screenshots, full page source, localStorage
and browser request bodies are deliberately not attached automatically. Selenium,
Appium, OS process inspection and debug-level HTTP logging are separate trust
boundaries: protect their logs and host access. Explicit screenshots on staging
may still contain private account or wallet information.

The deterministic fixtures do not verify Cowboy endpoints, live ECAI, invoice
mutation, actual report fetching/streaming, wallet signatures or native apps.
Use the live selections and existing integration suites for those boundaries.
Successful fixture checks must never be reported as live-node or device passes.

## Reference contracts

Implementation references (reviewed while preparing this change):

- W3C WebDriver commands and sessions: <https://www.w3.org/TR/webdriver/>
- Selenium explicit waits and avoiding mixed implicit/explicit waits:
  <https://www.selenium.dev/documentation/webdriver/waits/>
- Appium namespaced capabilities:
  <https://appium.io/docs/en/latest/guides/caps/>
- Appium Android prerequisites and driver installation:
  <https://appium.io/docs/en/latest/quickstart/uiauto2-driver/>
- Rebar3 Common Test invocation: <https://rebar3.org/docs/testing/ct/>

Before merging, run both the new EUnit tests and the selected real WebDriver
profile in the complete repository. The authoring environment did not provide
Erlang/rebar3, ChromeDriver, Selenium Grid, Appium, Android or iOS, so compilation,
the actual W3C client and live/device executions were not verified there.
