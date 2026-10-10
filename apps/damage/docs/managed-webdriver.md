# DamageBDD-managed ChromeDriver and Appium

This change builds on the native dashboard WebDriver test patch. DamageBDD now
owns provisioning and the ChromeDriver/Appium OS processes. Browser steps use
the same managed profiles in a normal Damage execution or in the local Common
Test harness. Starting a browser test no longer requires separate terminals
running ChromeDriver, Appium or the optional source-tree fixture server.

The runtime is disabled by default. Enabling services does not automatically
execute a feature, perform a payment, or bypass Damage authorization/accounting.

## Enable in sys.config

Merge the keys from `priv/config/webdriver.sys.config` into the existing
`{damage, [...]}` application entry in your real `config/sys.config`. Do not
replace your other node settings. The example enables managed desktop Chrome;
Appium is explicitly disabled until its SDK/JDK/device settings have been reviewed.

Smallest desktop addition:

```erlang
{webdriver_runtime, [
    {enabled, true},
    {data_dir, "/var/lib/damage/webdriver"},
    {bootstrap, true},
    {offline, false},
    {chromedriver, [
        {enabled, true}, {source, download}, {version, stable},
        {port, 9515}, {max_sessions, 1}
    ]}
]},
{webdriver, [
    {managed, chromedriver},
    {dashboard_url, <<"http://127.0.0.1:8080">>},
    {fixture, false},
    {credentials, [
        {username, {env, "DAMAGE_DASHBOARD_TEST_USERNAME"}},
        {password, {env, "DAMAGE_DASHBOARD_TEST_PASSWORD"}}
    ]},
    {capabilities, [
        {browserName, <<"chrome">>},
        {'goog:chromeOptions', [
            {args, [<<"--headless=new">>, <<"--window-size=1440,1200">>]}
        ]}
    ]}
]}
```

The URL is the dashboard being tested, not the WebDriver server. Set its actual
port/address. Do not set `endpoint` on a managed profile: Damage derives that
from the supervised service. The provisioned Chrome executable is injected into
`goog:chromeOptions.binary` so a different host Chrome cannot be selected by accident.

All configuration objects use nested tuple lists. Capability strings are binaries
and capability arrays are lists of binaries. Unknown/duplicate runtime keys,
invalid ports, public bind overrides and duplicate enabled-service ports are rejected.

Without `data_dir`, the runtime reuses `damage_config:state_dir()/webdriver`,
including the node's configured state directory and XDG/HOME fallback. Use one
private cache per node instance. The cache must not be under a published run
or report directory. Newly created directories are private; symlink ancestors
and group/world-writable backend roots are rejected.

Start Damage normally (`rebar3 shell` with your existing configuration, or the
packaged service). `damage_sup` starts `damage_webdriver_sup`, whose workers return
from init immediately and perform provisioning in owned external processes.

## What gets installed

| Component | Managed behaviour |
|---|---|
| Desktop browser + driver | Download a matching Chrome for Testing and ChromeDriver build, extract privately, compare build versions, and inject the browser path. |
| Node.js + npm | Download an LTS Node distribution with bundled npm, verify the official SHA-256, and validate Appium's Node/npm requirements. Existing Node can be selected explicitly. |
| Appium | Resolve an Appium 3 version once, write a private npm package/lock, install with `npm ci`, and run through its private Node executable. No global npm install. |
| UiAutomator2 / XCUITest | Install only explicitly selected, pinned/resolved driver versions into a private `APPIUM_HOME`; run their required-dependency Doctor checks. XCUITest requires macOS. |
| Java | Use an explicit JDK home, or fetch an operator-selected HTTPS archive with a required SHA-256 and an explicit in-archive JDK home. |
| Android SDK | Use an existing SDK without installing packages into it, or fetch checked command-line tools and install the selected SDK packages into a private SDK. License acceptance must be explicitly enabled. |
| Android ChromeDriver | Optionally allow ONLY `uiautomator2:chromedriver_autodownload`, using a separate private cache for Android's Chrome/WebView version. Alternatively provide an explicit compatible executable for offline use. |

`priv/config/webdriver-android-downloads.config.example` contains the JDK/SDK
checked-download recipe. It deliberately contains placeholders; choose the
archive for your host, obtain the publisher's digest and review licenses before
enabling it. Do not use the example's placeholders as real deployment values.

The managed host requires an **unprivileged account, Python 3.10+, CA trust and
browser/SDK operating-system libraries**. The installer never invokes sudo,
apt, pacman or a global package manager, and refuses to run as root. Provision
that OS base through your existing host image/package-management policy. Chrome
For Testing downloads in this implementation support Linux x86-64 and macOS
x86-64/arm64; Linux ARM requires explicit compatible system browser/driver paths.
Windows hosts are not supported by this POSIX/erlexec provisioner.

Android USB authorization, a suitable connected device or existing AVD, USB
permissions/KVM and macOS Xcode/simulator/signing setup are host prerequisites.
Installing SDK image packages does not create an AVD. A trusted profile may use
`appium:avd` to let UiAutomator2 launch an existing AVD. This patch does not create
devices, install Xcode or accept its license. ADB/emulator services that daemonize
or were already running are platform tooling, not separately supervised OTP
children; use a dedicated test host/account. Do not treat process-group cleanup
as a sandbox for arbitrary programs which deliberately detach themselves.

## Enable Appium and Android

In the full sys.config example, set `appium.enabled` to `true` after adjusting
Java/SDK paths (or replacing them with the download recipe). Set the named
`android` profile's `appium:udid` to the intended dedicated device. A missing,
offline or incompatible device fails session creation; `/status` health is not
proof of device readiness. Doctor checks the toolchain, not every device state.

For Android emulators, `10.0.2.2` commonly addresses the emulator host. For real
or remote devices use an address reachable from the device. Keep the Appium
control service bound to loopback; only the target dashboard needs device access.

The Node and Appium process environments are rebuilt from a small allowlist.
Parent `DAMAGE_SECRET_KEY`, SSH-agent settings, npm credentials, `NODE_OPTIONS`,
Python hooks and test-account passwords are not inherited by those processes.
The Erlang browser client reads only the credential aliases explicitly configured
for the test profile. Do not place passwords directly in feature text.

`chromedriver_autodownload=true` is a narrowly scoped Appium exception, not
`--relaxed-security`. It is removed when `offline=true` or `bootstrap=false`.
Offline Android tests need an already populated compatible driver cache or
`android_chromedriver` pointing to a matching binary. Android's installed Chrome
need not match the desktop Chrome for Testing version.

## Versions, integrity and offline operation

`stable`, `latest` and `lts` are **first-resolution selectors, not automatic update
policies**. `selection-<config-id>.json` records exact selected versions. Normal
restarts reuse them. Configuration-addressed installation directories are
published through `runtime.json` only after successful provisioning/checks.
File locking prevents concurrent installers writing one backend cache.

Node archives are checked against the publisher's HTTPS-served checksum list.
JDK/Android command-tools downloads require operator-supplied SHA-256 digests.
Chrome archives accept optional pinned SHA-256 values; without them, the initial
trust boundary is the official HTTPS download, after which the observed hash is
recorded and reused. Hashing an initial download is not an independent publisher
signature. Pin versions AND known digests for stricter release control.

The private Appium core npm lock is retained and reused on retries. Core npm
installation disables lifecycle scripts. Appium driver installation may run its
own npm install hooks/device-binary setup; it remains third-party code running as
the dedicated account. The recorded inventory verifies selected executables and
entry points on restart, not every transitive file in npm, browser resources or
SDK storage. Keep the cache private and review the dependency supply chain.

After a successful initial installation, set `offline=true`, optionally also
`bootstrap=false`, and restart the idle backend. Complete matching installations
are reused without dependency downloads. Offline mode does not reconstruct a
partial install from cached archives and does not block the test browser's own
network requests to the target dashboard. Installer HTTPS requests use approved
hosts and reject HTTPS downgrades/credential-bearing URLs; npm and SDK tools use
their own package transport. There is no inherited Damage Tor/proxy configuration
for these subprocesses or for local driver health checks.

Changing the requested version creates another configuration-addressed generation.
The previous generation is not an automatic rollback target. Keep previous caches
until the new version has passed your validation. Tampered/incomplete installs
fail closed rather than silently upgrading. After stopping the backend, remove
or move its `runtime.json` only when intentionally reprovisioning/refreshing an
owned source-tree fixture; do not clear a live cache. Download caches do not have
a size-based eviction policy: plan disk capacity and perform explicit offline
maintenance of old generations.

## Process ownership, readiness and failure behaviour

The supervision tree is:

```text
damage_sup
  damage_webdriver_sup
    damage_webdriver_chromedriver  (damage_webdriver_service)
    damage_webdriver_appium        (damage_webdriver_service)
    damage_webdriver_fixture       (damage_webdriver_service)
```

Each enabled worker owns an `erlexec` bootstrap process, then its server process.
Commands are argument lists, not shell strings. Each child has its own process
group, monitored exit, graceful-stop deadline and process-group termination.
An occupied configured port is an error: the runtime never intentionally attaches
to, adopts or kills the pre-existing server. Use remote `endpoint` profiles for
servers managed elsewhere.

The service progresses through `installing`, `starting`, `ready`, `backoff` and,
after bounded repeated failures, `failed`. A healthy interval resets the failure
budget. Startup requires a valid readiness response; a busy response after startup
is not automatically treated as a crashed driver. Failed downloads/Doctor checks
and missing binaries become backend failures without crashing the main Damage
supervisor. Correct the problem and request an explicit restart after the failure
budget is exhausted.

Each browser client reserves a slot against a specific service pid and generation.
Default capacity is one session. Capacity exhaustion fails explicitly; it is not
an unbounded queue. Client exit/release frees capacity. Administrative stop/restart
is refused while a reservation is active. Unexpected driver loss invalidates its
sessions rather than replaying browser actions. A failed/timed-out session creation
or failed session deletion recycles the owned backend because the remote session
state may be unknown; with multi-session capacity this also fails other sessions
on that backend rather than risking orphaned sessions.

`damage:execute_steps/3` now cleans up the owned WebDriver client in a `try/after`
scenario scope. This covers another step failing before the explicit browser-close
step, exceptions, normal scenarios and outline rows. Client owner monitoring,
idle expiry and maximum session lifetime remain additional cleanup mechanisms.
Existing remote profiles retain browser-session cleanup but their servers are
not restarted or terminated by Damage.

## Operator commands

From the trusted node shell:

```erlang
damage_webdriver_runtime:status().
damage_webdriver_runtime:status(chromedriver).
damage_webdriver_runtime:await(chromedriver, 960000).
damage_webdriver_runtime:restart(appium).
damage_webdriver_runtime:stop(appium).
```

`restart/1` rereads application environment configuration; it does not consult a
sys.config file that was edited on disk. Restart the node after editing sys.config,
or update the existing application environment deliberately before restarting the
idle backend. Use configuration `enabled=false` for a persistent disable; `stop/1`
is an in-memory administrative stop until explicitly restarted or the node reboots.

Status includes phase, active sessions, failure counters, OS pid and recorded
version selections. Lifecycle notices use OTP Logger. Dependency/driver output
is kept in `<data_dir>/<backend>/process.log`, rotated at 4 MiB with three retained
files, mode 0600. Bootstrap output buffers have bounded memory; the installer may
use a temporary output file until a command completes. Treat all driver/install
logs as potentially sensitive, even with warning-level logging and Appium's
`X-Appium-Is-Sensitive` header. Do not publish them to IPFS or execution reports.

## Run the full source-tree dashboard suite with no manual driver processes

```sh
rebar3 compile
rebar3 eunit --module=damage_webdriver_tests
rebar3 eunit --module=damage_webdriver_runtime_tests

rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/managed-fixture.config
```

The CT profile enables ChromeDriver and the production-template/simulated-service
fixture. The harness derives the fixture script path from its own source tree,
starts an isolated `damage_webdriver_sup`, waits for readiness, runs the existing
27 selected desktop scenarios and stops only its own supervisor at the end.
It restores the application environment/temporary local test authorization.
It refuses to run this isolated harness inside an already running Damage application.
Run the CT VM as a non-root user with a writable private cache.

For the 25 selected Android mobile fixture scenarios, edit SDK/JDK/device settings:

```sh
rebar3 ct \
  --suite=apps/damage/test/damage_dashboard_webdriver_SUITE \
  --config=apps/damage/test/webdriver/managed-android-fixture.config
```

The fixture uses simulated APIs; these are not live ECAI, wallet or invoice API
integration tests. The fixture depends on the source tree and is not a production
release service. A packaged node can run live dashboard tests without that fixture.

`managed-node.config` demonstrates importing the three WebDriver keys from an
actual sys.config and selecting a named profile. Set `webdriver_sys_config` to
an absolute deployment configuration path, choose `desktop` or `android`, and
select the appropriate live suite groups. ECAI generation and billing remain
explicit suite selections, not automatic side effects of bootstrapping. Do not
set `DAMAGE_WEBDRIVER_URL` for a managed profile: mixing a managed service with an
explicit endpoint is rejected. `DAMAGE_DASHBOARD_URL` can override the test target.

## Normal DamageBDD execution and scheduling

The `webdriver` key supplies the default profile to ordinary features. A trusted
feature can select a named entry in `webdriver_profiles`:

```gherkin
Given I use WebDriver profile "desktop"
Given I start the configured WebDriver browser
Given I open the authenticated WebDriver dashboard
Then the WebDriver element "#bdd-prompt" should be "visible"
Then I close the WebDriver browser
```

`steps_webdriver` retains the `node_admin` annotation AND runtime role check.
Profiles, commands, ports, package versions and executable paths cannot be supplied
by an unprivileged feature through this step. Selecting a profile does not elevate
the target dashboard test account's role.

Two release-packaged smoke features are provided under `priv/features/dashboard/`.
Submit one through the existing feature execution API (or dashboard/scheduler):

```sh
curl --fail-with-body --no-buffer \
  -H "Authorization: Bearer $DAMAGE_ACCESS_TOKEN" \
  -H 'Content-Type: text/plain' \
  --data-binary @apps/damage/priv/features/dashboard/managed-desktop.feature \
  "$DAMAGE_URL/execute_feature/"
```

Use `managed-android.feature` for the Android profile. The existing eight full
suite feature files under `test/damage_dashboard_webdriver_SUITE_data/` also use
native Damage step syntax and can be submitted individually with a suitable
default profile. Fixture-only features must target the enabled fixture.

**Normal execution uses the existing authorization, balance checks, run context,
formatters, report publication and charging.** The local CT harness is a distinct
non-paying developer test path. Neither bootstrapping nor these changes disable
normal runner accounting. The smoke tests do not press the dashboard's Run button
or perform wallet transfers, but submitting the outer BDD feature itself can incur
normal verification costs. No self-test is automatically scheduled at node startup.

## Verification and deployment gates

Offline helper tests need only the standard Python library:

```sh
python3 apps/damage/test/scripts/webdriver_bootstrap_test.py
```

An optional real-OTP process suite starts a tiny fake HTTP child with the actual
installer and erlexec, with downloads disabled. It checks start/stop, child-crash
recovery, port ownership, capacity/restart guards and uncertain-session recycling:

```sh
DAMAGE_WEBDRIVER_RUNTIME_TEST=1 rebar3 ct \
  --suite=apps/damage/test/damage_webdriver_runtime_SUITE
```

The process suite is not a browser/Appium test. It is skipped unless opted in.
Run it unprivileged. Then run the managed Chrome fixture suite, the Android suite
on a dedicated device, and your staging login/ECAI/billing selections. Confirm
service shutdown does not leave owned browser processes and verify your pinned
SDK/driver combinations before release. Compilation and these actual OTP/browser/
device integration runs were not possible in the patch-authoring environment;
see the delivered verification record for checks that did run.

## Upstream references

- erlexec process groups, argument vectors and shutdown: https://hexdocs.pm/erlexec/exec.html
- ChromeDriver matching versions: https://developer.chrome.com/docs/chromedriver/downloads/version-selection
- ChromeDriver security: https://developer.chrome.com/docs/chromedriver/security-considerations
- Chrome for Testing builds: https://googlechromelabs.github.io/chrome-for-testing/
- Appium requirements: https://appium.io/docs/en/latest/quickstart/requirements/
- Appium server flags: https://appium.io/docs/en/latest/reference/cli/server/
- Appium extension management: https://appium.io/docs/en/latest/guides/managing-exts/
- Appium status schema: https://appium.io/docs/en/latest/reference/api/webdriver/#getstatus
- Appium sensitive logs: https://appium.io/docs/en/3.4/developing/sensitive/
- UiAutomator2 setup and ChromeDriver selection: https://github.com/appium/appium-uiautomator2-driver
- Android SDK packages/licenses: https://developer.android.com/tools/sdkmanager
