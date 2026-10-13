import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = async (relative) => readFile(new URL(relative, root), 'utf8');
const shell = await read('priv/templates/ui/dashboard/page_shell.mustache');
const guest = await read('priv/templates/ui/dashboard/guest_landing.mustache');
const dashboard = await read('src/damage_dashboard.erl');
const routes = await read('src/damage_app.erl');
const quickstartHtml = await read('priv/static/quickstart.html');

// Matches only the scalar/section subset used by this contract test.
function render(src, ctx) {
  const section = /{{([#^])\s*(\w+)\s*}}((?:(?!{{[#^]).)*?){{\/\2\s*}}/gs;
  while (section.test(src)) {
    section.lastIndex = 0;
    src = src.replace(section, (_, kind, key, body) => Boolean(ctx[key]) === (kind === '#') ? body : '');
    section.lastIndex = 0;
  }
  return src.replace(/{{{\s*(\w+)\s*}}}/g, (_, key) => ctx[key] || '');
}

test('unauthenticated root shows prominent URL-to-feature onboarding without workspace panels', () => {
  const html = render(shell, {authenticated:false, guest_landing:guest});
  assert.match(html, /id="guest-main"/);
  assert.match(html, /id="guest-hero-title"/);
  assert.match(html, /action="\/try" method="get"/);
  assert.match(html, /name="url"[^>]+required/);
  assert.match(html, /data-guest-auth="login"/);
  assert.match(html, /data-guest-auth="signup"/);
  assert.match(html, /href="\/install"/);
  assert.match(html, /href="\/try"/);
  assert.doesNotMatch(html, /data-dashboard-shell/);
});

test('authenticated dashboard retains workspace and omits guest marketing', async () => {
  const html = render(shell, {authenticated:true, guest_landing:guest});
  assert.match(html, /data-dashboard-shell/);
  assert.doesNotMatch(html, /id="guest-landing"/);
  assert.match(await read('priv/templates/ui/dashboard/sidebar.mustache'), /href="\/try"/);
});

test('anonymous modal no longer auto-opens and generation retains the existing route', async () => {
  assert.match(dashboard, /auth_auto_open\s*=>\s*<<"false">>/);
  assert.match(dashboard, /auth_allow_guest\s*=>\s*true/);
  assert.match(dashboard, /guest_landing\s*=>\s*GuestLanding/);
  assert.match(routes, /\{"\/try", cowboy_static/);
  assert.match(routes, /\{"\/api\/quickstart\/generate", damage_quickstart_http/);
  assert.match(quickstartHtml, /id="connect-form"/);
  assert.match(await read('priv/static/js/quickstart.js'), /function prefillFromDashboard\(\)/);
});

test('guest sign-in buttons delegate to existing DamageAuth rather than introducing a second auth stack', async () => {
  const modes = [];
  const makeButton = mode => ({ dataset:{guestAuth:mode}, listeners:{}, addEventListener(t, f){ this.listeners[t]=f; } });
  const login = makeButton('login');
  const signup = makeButton('signup');
  const rootEl = { dataset:{}, querySelectorAll(){ return [login,signup]; } };
  const oldDocument = globalThis.document, oldWindow=globalThis.window;
  globalThis.document = {readyState:'complete', getElementById(id){ return id==='guest-landing'?rootEl:null; }};
  globalThis.window = {DamageAuth:{open(mode){ modes.push(mode); }}};
  try {
    const src = await read('priv/static/js/dashboard-guest.js');
    const mod = await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'));
    login.listeners.click(); signup.listeners.click();
    assert.deepEqual(modes, ['login','signup']);
    mod.bindGuestActions(); // idempotent under hot reload
    assert.equal(rootEl.dataset.bound, 'true');
  } finally {
    globalThis.document=oldDocument; globalThis.window=oldWindow;
  }
});
