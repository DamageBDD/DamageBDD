import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

test('wallet is a dashboard workspace instead of a modal', async () => {
  const [shell, sidebar, topbar, wallet] = await Promise.all([
    read('priv/templates/ui/dashboard/page_shell.mustache'),
    read('priv/templates/ui/dashboard/sidebar.mustache'),
    read('priv/templates/ui/dashboard/topbar.mustache'),
    read('priv/templates/ui/dashboard/wallet_tab.mustache')
  ]);
  assert.match(shell, /id="wallet-tab"[^>]+data-dashboard-view/);
  assert.match(shell, /\{\{\{wallet_tab\}\}\}/);
  assert.doesNotMatch(shell, /\{\{\{wallet_modal\}\}\}/);
  assert.match(sidebar, /id="dashboard-link-wallet"[^>]+data-dashboard-panel="wallet-tab"/);
  assert.doesNotMatch(topbar, /data-micromodal-trigger="wallet-modal"/);
  assert.match(wallet, /id="invoice-form"/);
  assert.match(wallet, /id="transfer-out-form"/);
  assert.match(wallet, /id="wallet-connections"/);
  assert.match(wallet, /id="wallet-recent-activity"/);
});

test('logout copy describes a browser session rather than global account revocation', async () => {
  const logout = await read('priv/templates/ui/dashboard/logout_modal.mustache');
  assert.match(logout, /Sign out of this browser\?/);
  assert.match(logout, /wallet accounts, balances and funds are not deleted/i);
  assert.doesNotMatch(logout, /Logout of all accounts/i);
  assert.match(logout, /modal__btn-danger/);
});

test('wallet page loads the shared wallet workspace assets', async () => {
  const shell = await read('priv/templates/ui/dashboard/page_shell.mustache');
  assert.match(shell, /dashboard-wallet\.css/);
  assert.match(shell, /wallet-dashboard\.js/);
});

test('sign-out confirmation never stacks the authentication dialog behind it', async () => {
  const [sidebar, main, auth] = await Promise.all([
    read('priv/templates/ui/dashboard/sidebar.mustache'),
    read('priv/static/js/main.js'),
    read('priv/static/js/auth-ui.js')
  ]);
  // The logout control has one owner. MicroModal's declarative trigger used to
  // race the explicit click handler and made modal state harder to reason about.
  assert.doesNotMatch(sidebar, /id="logoutBtn"[^>]+data-micromodal-trigger="logout-modal"/);
  assert.match(main, /MicroModal\.close\("login-modal"\)[\s\S]{0,180}MicroModal\.show\("logout-modal"\)/);
  assert.match(main, /await window\.logoutActiveSession\(\)[\s\S]{0,520}MicroModal\.close\("logout-modal"\)[\s\S]{0,120}window\.location\.reload\(\)/);
  assert.match(auth, /getElementById\('logout-modal'\)\?\.classList\.contains\('is-open'\)/);
});
