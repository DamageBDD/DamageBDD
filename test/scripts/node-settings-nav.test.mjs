import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../apps/damage/priv/static/js/damage-node-settings-nav.js', import.meta.url), 'utf8');

function element(tagName, onRemove = () => {}) {
  return {
    tagName: tagName.toUpperCase(), children: [], attributes: {},
    setAttribute(k, v) { this.attributes[k] = v; },
    append(...nodes) { this.children.push(...nodes); },
    remove() { onRemove(this); },
    closest() { return null; }
  };
}

function fixture(status, payload = { version: 'abc' }) {
  let section = null;
  let css = null;
  const nav = element('nav');
  nav.append = (...nodes) => { section = nodes.at(-1); nav.children.push(...nodes); };
  const head = element('head');
  head.append = (...nodes) => { css = nodes.at(-1); head.children.push(...nodes); };
  const listeners = {};
  const document = {
    readyState: 'complete', visibilityState: 'visible', head,
    querySelector(selector) {
      if (selector === '[data-damage-node-admin-navigation]') return section;
      if (selector === '[data-damage-node-settings-nav-css]') return css;
      if (selector === '[data-dashboard-sidebar] nav') return nav;
      return null;
    },
    createElement(tag) {
      return element(tag, () => { if (section?.tagName === tag.toUpperCase()) section = null; });
    },
    addEventListener(event, callback) { listeners[event] = callback; }
  };
  const window = { addEventListener(event, callback) { listeners[event] = callback; } };
  const fetch = async (url) => {
    assert.equal(url, '/api/admin/settings/status');
    return {
      status,
      headers: { get: () => 'application/json; charset=utf-8' },
      json: async () => payload
    };
  };
  vm.runInNewContext(source, { document, window, fetch, location: { pathname: '/dashboard' } });
  return { getSection: () => section, listeners, nav };
}

const flush = () => new Promise(resolve => setImmediate(resolve));

test('non-admin 403 cannot create navigation', async () => {
  const page = fixture(403, { error: 'node_admin_required' });
  await flush();
  assert.equal(page.getSection(), null);
});

test('success from protected endpoint creates separate node-admin section', async () => {
  const page = fixture(200, { version: 'abc' });
  await flush();
  const section = page.getSection();
  assert.ok(section);
  assert.equal(section.attributes['aria-label'], 'Node administration');
  assert.equal(section.children[1].href, '/dashboard/node/settings');
});

test('200 without admin status shape does not create navigation', async () => {
  const page = fixture(200, { error: 'login_required' });
  await flush();
  assert.equal(page.getSection(), null);
});
