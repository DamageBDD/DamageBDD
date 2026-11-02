# DamageBDD Recorder 0.1.1

Record locally, review the timeline, and export replayable DamageBDD Gherkin.
The Chrome/Firefox extension does not upload recordings or execute paid tests.

## Upgrade the current DamageBDD source

Extract `damagebdd-recorder-latest-update.zip` into your monorepo root. It updates
only this extension directory and installs a backend patch under `patches/`;
it does not replace your repository README or configuration.

```sh
git apply --check patches/0002-browser-recorder-current-webdriver.patch
git apply patches/0002-browser-recorder-current-webdriver.patch
rebar3 compile
rebar3 eunit --module=steps_browser_recorder_tests
node --test extensions/damagebdd-recorder/tests/*.test.mjs
```

Do **not** apply the old `0001-wire-browser-recorder-steps.patch`. Current
DamageBDD automatically discovers step modules and filters them by role.

Replay uses the existing configured WebDriver profile and requires `node_admin`,
matching the current automation subsystem. Recording and exporting need no login.
Detected private fields become account-scoped secret names. Old node-scoped
recorder secrets need to be provisioned in the replaying account's scope.

After applying the patch, full setup, configuration, privacy notes, supported
steps, limitations and verification status are documented in
`apps/damage/docs/browser-recorder.md`.

## Load the extension

Chrome: open `chrome://extensions`, enable Developer mode, choose **Load
unpacked**, and select this directory. Firefox: open
`about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and
select `manifest.json`. These are unsigned development packages.
Reload the extension and test pages after an upgrade to replace old content
scripts. Do not upgrade in the middle of an active recording.

## First recording

Open a test site, click the recorder toolbar icon and choose **Start recording**.
Click, type, select and navigate naturally. Use **Add a text assertion** to select
a visible success message. Finish, review the generated feature and export it.
Keep the starting page first in the timeline. Detected private values are not
captured; normal fields and titles still need a privacy review.

The recorder supports one tab and normal page DOM controls. New tabs, iframes,
shadow-root controls, file uploads, canvas, rich editors and multi-select fields
are outside the supported scope. Recordings stay in extension-local storage;
use test accounts and delete recordings you no longer need.

## Tests in this update

16 Node tests and JavaScript syntax checks passed. Three of those tests inspect
source contracts; they do not execute Erlang. Twelve EUnit cases were added but
not run in the available environment, which has no Erlang/rebar3 installation.
Live browser loading and WebDriver replay still require local validation.
