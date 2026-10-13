# Authentication module loading recovery

## Observed symptoms

`auth-ui.js` requests `connectBrowserForAuth` and `signBrowserForAuth` from
`wallet.js`. A named-import link failure prevents the auth UI from initializing;
email, signup and recovery should not depend on successfully loading a wallet.

The previously delivered rebased wallet.js already exports both functions (lines
356 and 370 in that exact artifact). Its SHA-256 is:

```
9a8aa9058a0e59660f7b1890119ee2838546e3a7e9b8b479f9b0a4099e999dc5
```

The console error establishes incompatible modules in the browser. It does not
establish whether the cause is browser/proxy caching, an old release priv tree,
an incomplete deployment, or different versions behind a load balancer.

## Focused change

- Remove the eager wallet named import from auth-ui.js. Only clicking a browser
  wallet action loads the wallet module through auth-wallet-loader.js.
- Request the wallet with a stable content-derived cache key and validate both
  authentication exports. Catch network, linking and evaluation errors and show
  a recoverable message in the existing UI. No legacy connection/transaction
  fallback is attempted.
- Check cancellation after module loading, before invoking wallet RPC. Already
  running provider RPCs still follow the existing provider timeouts.
- Version the auth-ui entrypoint in page_shell.mustache. The new loader uses a
  new filename; the existing wallet.js source is not modified by this patch.
- Add real ES-module linker tests, loader tests and browser DOM regressions for
  missing exports, syntax errors and top-level module errors.

The cache key is not an integrity check or an immutable asset server. A wrong
wallet.js on disk must still be corrected. Deploy all assets together to every
node. Reload after repairing an invalid module: clearing the loader promise is
not a way to invalidate the browser's successfully loaded module namespaces or
cached evaluation failures. On future wallet.js edits update its cache key; the
new test checks it against the source bytes. This change is not a full app-wide
fingerprinted asset pipeline and does not repair other mixed-version assets.

## The session 401

No authentication policy or backend response changes are included. In the
previously delivered damage_browser_auth_http module, `/accounts/session`
returns 401 for an absent/expired/invalid browser session; wallet-switcher.js
explicitly clears its in-memory session and returns null on this response. That
is the signed-out state, not a reason to authenticate the caller or return a
success payload. The loader fix lets that state open the login UI normally.

A 401 that persists after a successful login is a different fault. Inspect the
login response's `sessionid` Set-Cookie and whether the next session request sends
it, the exact host/origin, HTTPS/Secure cookie configuration and node-local
session ownership. Do not paste bearer tokens or cookies into tickets. Sessions
in this implementation are invalidated by auth service restarts; multiple nodes
need consistent routing. Do not disable Secure cookies on a public HTTP origin.

## Diagnose served versus checked-out assets

From the dashboard's browser console (imports but does not call wallet APIs):

```js
const walletModule = await import(`/static/js/wallet.js?diagnostic=${Date.now()}`);
console.table({
  connectBrowserForAuth: typeof walletModule.connectBrowserForAuth,
  signBrowserForAuth: typeof walletModule.signBrowserForAuth
});
```

Both values should be `function`. If the cache-busted URL exports the functions
but the original import fails, force a reload with DevTools Network > Disable
cache enabled. If the fresh URL also lacks them, inspect the actual deployed
file before clearing more caches.

In the repository:

```sh
grep -nE '^export async function (connectBrowserForAuth|signBrowserForAuth)' \
  apps/damage/priv/static/js/wallet.js
```

In the running Erlang node:

```erlang
code:priv_dir(damage).
```

Check `static/js/wallet.js` under that directory. The application route uses
Cowboy's `{priv_dir, damage, "static/"}`: editing a source checkout does not
necessarily update an independently installed release. A reverse proxy can also
serve a different static directory, so compare HTTP bytes as well. The companion
compatible wallet.js is an unchanged copy from the last rebased source bundle;
compare it before restoring it, preserving any subsequent local edits.

## Apply

This is incremental on top of damagebdd-auth-wallet-flow-rebased.patch, not a
replacement for that authentication implementation. It changes seven paths and
does not modify wallet.js, OTP services, session policies or payment paths.

```sh
PATCH="$HOME/Downloads/damagebdd-auth-module-loading-fix.patch"
git apply --check --whitespace=error "$PATCH" &&
git apply --whitespace=error "$PATCH" &&
node --experimental-vm-modules --test \
  apps/damage/test/scripts/auth_module_loading.test.mjs \
  apps/damage/test/scripts/auth_model.test.mjs
```

The vm flag is for Node's ES-module linker test API; there is no new production
JavaScript dependency. The browser tests use the existing Playwright setup:

```sh
python3 apps/damage/test/scripts/auth_module_loading_browser_test.py
python3 apps/damage/test/scripts/auth_browser_test.py --dom-only
```

These DOM tests explicitly simulate wallet transport, services, origin, Storage
and reload. They do not validate real cookies, HTTP caching, a live wallet,
Cowboy/OTP, or Selenium/Appium. The existing HTTP fixture suite remains available
without `--dom-only` on a host that permits loopback browser navigation.

## Verified in the patch environment

52 Node tests passed (14 new linker/loader/session checks and 38 existing checks).
14 new module-failure Chromium DOM checks and 64 existing auth DOM checks passed
with no uncaught page exceptions. Direct Chromium HTTP navigation was attempted
and blocked by the environment (`ERR_BLOCKED_BY_ADMINISTRATOR`), so no live HTTP,
cache or cookie result is claimed. Erlang/rebar3 is unavailable here; no Erlang
source was changed. Patch application and reverse-application were checked
against the reconstructed last-delivered auth baseline.
