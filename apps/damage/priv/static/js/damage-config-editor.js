// DamageBDD settings editor. Auth lives on the server; no credentials in JS.
const app = document.body.dataset.settingsApp;
const api = `/api/admin/settings/${app}`;
const fieldsEl = document.querySelector('#settings-fields');
const form = document.querySelector('#settings-form');
const saveButton = document.querySelector('#settings-save');
const discardButton = document.querySelector('#settings-discard');
const refreshButton = document.querySelector('#settings-refresh');
const notice = document.querySelector('#settings-notice');
const search = document.querySelector('#settings-search');
let config = null;
let controls = new Map();
let featureControls = new Map();
let touched = new Set();
let busy = false;

for (const anchor of document.querySelectorAll('[data-app-tab]')) {
  if (anchor.dataset.appTab === app) anchor.setAttribute('aria-current', 'page');
}

function showNotice(message, kind = 'info') {
  notice.hidden = false;
  notice.dataset.kind = kind;
  notice.textContent = message;
}
function clearNotice() { notice.hidden = true; notice.textContent = ''; }
function setBusy(value) {
  busy = value;
  saveButton.disabled = value;
  discardButton.disabled = value;
  refreshButton.disabled = value;
  for (const control of controls.values()) {
    control.input.disabled = value;
    if (control.reset) control.reset.disabled = value;
  }
}
async function jsonRequest(url, method = 'GET', payload = null) {
  const options = { method, credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' } };
  if (method !== 'GET') {
    options.headers['Content-Type'] = 'application/json';
    options.headers['X-Damage-Settings-Action'] = '1';
    options.body = JSON.stringify(payload || {});
  }
  const response = await fetch(url, options);
  let data;
  try { data = await response.json(); } catch { data = { error: `HTTP ${response.status}` }; }
  if (!response.ok) {
    const message = typeof data.error === 'string' ? data.error : `HTTP ${response.status}`;
    const error = new Error(data.reason ? `${message}: ${data.reason}` : message);
    error.httpStatus = response.status;
    throw error;
  }
  return data;
}
function asInputValue(field) {
  const v = field.value;
  if (field.type === 'boolean') return v === true;
  if (field.type === 'string_list') return Array.isArray(v) ? v.join('\n') : '';
  return v == null ? '' : String(v);
}
function readValue(field, input) {
  if (field.type === 'boolean') return input.checked;
  if (field.type === 'integer' || field.type === 'parallelism') {
    const text = input.value.trim();
    if (field.type === 'parallelism' && text === 'auto') return 'auto';
    if (!text) throw new Error(`${field.label}: enter an integer`);
    const n = Number(text);
    if (!Number.isSafeInteger(n) || n < field.min || n > field.max) {
      throw new Error(`${field.label}: must be between ${field.min} and ${field.max}`);
    }
    return n;
  }
  if (field.type === 'string_list') {
    return input.value.split(/\r?\n/).map(v => v.trim()).filter(Boolean);
  }
  const s = input.value.trim();
  if (!s) throw new Error(`${field.label}: value cannot be empty`);
  return s;
}
function sameValue(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function collectChanges() {
  if (!config) return {};
  const changes = {};
  for (const field of config.fields) {
    const { input } = controls.get(field.name);
    const original = asInputValue(field);
    const isChanged = field.type === 'boolean' ? input.checked !== original :
      input.value !== original;
    if (!isChanged && !(field.value == null && touched.has(field.name))) continue;
    const value = readValue(field, input);
    if (field.value == null || !sameValue(value, field.value)) changes[field.name] = value;
  }
  return changes;
}
function updatePending() {
  try {
    const changed = collectChanges();
    for (const [key, record] of controls) record.row.classList.toggle('dirty', Object.hasOwn(changed, key));
    const count = Object.keys(changed).length;
    document.querySelector('#settings-pending').textContent = count ? `${count} unsaved change${count === 1 ? '' : 's'}` : 'No unsaved changes';
    saveButton.disabled = busy || count === 0;
  } catch (error) {
    document.querySelector('#settings-pending').textContent = error.message;
    saveButton.disabled = true;
  }
}
function makeField(field) {
  const row = document.createElement('div');
  row.className = 'settings-field';
  const title = document.createElement('div');
  const titleEl = document.createElement('div');
  titleEl.className = 'settings-field-title';
  titleEl.textContent = field.label;
  const keyEl = document.createElement('div');
  keyEl.className = 'settings-field-key';
  keyEl.textContent = field.name;
  const meta = document.createElement('div');
  meta.className = 'settings-field-meta';
  const source = document.createElement('span');
  source.textContent = `Source: ${field.source}`;
  const policy = document.createElement('span');
  policy.className = `settings-live ${field.apply}`;
  policy.textContent = field.apply === 'hot' ? 'Live' : 'Restart';
  meta.append(source, policy);
  title.append(titleEl, keyEl, meta);
  if (field.help) {
    const help = document.createElement('p');
    help.className = 'settings-field-help';
    help.textContent = field.help;
    title.append(help);
  }
  const editor = document.createElement('div');
  editor.className = 'settings-field-edit';
  let input;
  if (field.type === 'string_list') {
    input = document.createElement('textarea');
    input.rows = 3;
    input.placeholder = 'One host or suffix per line';
  } else {
    input = document.createElement('input');
    input.type = field.type === 'boolean' ? 'checkbox' : field.type === 'integer' ? 'number' : 'text';
  }
  input.id = `setting-${field.name}`;
  input.setAttribute('aria-label', field.label);
  if (field.type === 'integer') { input.min = field.min; input.max = field.max; input.step = '1'; }
  const initial = asInputValue(field);
  if (field.type === 'boolean') input.checked = initial;
  else input.value = initial;
  input.addEventListener('input', () => { touched.add(field.name); updatePending(); });
  input.addEventListener('change', () => { touched.add(field.name); updatePending(); });
  editor.append(input);
  const reset = document.createElement('button');
  reset.type = 'button';
  reset.className = 'settings-reset';
  reset.textContent = 'Reset override';
  reset.hidden = !field.overridden;
  reset.addEventListener('click', () => resetField(field.name));
  editor.append(reset);
  row.append(title, editor);
  controls.set(field.name, { row, input, reset });
  return row;
}
function makeDiscovered(key) {
  // Only names, groups and restrictions are returned by the API. Never render
  // unknown runtime values: they may contain secrets or structured policies.
  const item = document.createElement('li');
  item.className = 'settings-discovered-key';
  const name = document.createElement('code');
  name.textContent = key.name;
  const state = document.createElement('span');
  state.className = `settings-discovered-status ${key.restriction === 'protected' ? 'protected' : ''}`;
  state.textContent = key.restriction === 'protected' ? 'Protected' : 'Not editable';
  item.append(name, state);
  return item;
}
function makeFeature(group, fields, discovered) {
  const section = document.createElement('section');
  section.className = 'settings-feature-section';
  section.id = `settings-feature-${group.id}`;
  section.dataset.featureName = group.label;

  const header = document.createElement('header');
  header.className = 'settings-feature-header';
  const heading = document.createElement('div');
  const title = document.createElement('h3');
  title.textContent = group.label;
  const description = document.createElement('p');
  description.textContent = group.description;
  heading.append(title, description);
  const counts = document.createElement('span');
  counts.className = 'settings-feature-counts';
  counts.textContent = `${fields.length} editable · ${discovered.length} discovered`;
  header.append(heading, counts);
  section.append(header);
  if (group.id === 'tax') {
    const guidance = document.createElement('p');
    guidance.className = 'settings-tax-guidance';
    guidance.textContent = 'Tax evidence uses a local private ledger. Enable it with a CLN owner address, save, and restart the node before starting a backfill. Reports require accounting review.';
    section.append(guidance);
    const isEnabled = fields.some(field => field.name === 'tax_enabled' && field.value === true);
    const pendingTaxRestart = (config?.pending_restart || []).some(name => name.startsWith('damage.tax_'));
    if (isEnabled && !pendingTaxRestart) {
      const reportsLink = document.createElement('a');
      reportsLink.className = 'settings-tax-reports-link';
      reportsLink.href = '/#node-tax-reports-tab';
      reportsLink.textContent = 'Open tax reports';
      section.append(reportsLink);
    } else {
      const notReady = document.createElement('p');
      notReady.className = 'settings-tax-not-ready';
      notReady.textContent = pendingTaxRestart
        ? 'Tax settings saved. Restart the node before accessing tax reports.'
        : 'Enable tax reporting, configure its owner and restart to access reports.';
      section.append(notReady);
    }
  }

  if (fields.length) {
    const rows = document.createElement('div');
    rows.className = 'settings-fields';
    rows.append(...fields.map(makeField));
    section.append(rows);
  }
  let details = null;
  const discoveredRows = new Map();
  if (discovered.length) {
    details = document.createElement('details');
    details.className = 'settings-discovered';
    const summary = document.createElement('summary');
    summary.textContent = `Other discovered configuration (${discovered.length})`;
    const help = document.createElement('p');
    help.textContent = 'Names only. These settings require explicit schema and policy review before dashboard editing is enabled.';
    const list = document.createElement('ul');
    list.className = 'settings-discovered-list';
    for (const key of discovered) {
      const item = makeDiscovered(key);
      discoveredRows.set(key.name, item);
      list.append(item);
    }
    details.append(summary, help, list);
    section.append(details);
  }
  return {section, details, discoveredRows};
}
function renderFeatures(data) {
  const nav = document.querySelector('#settings-feature-nav');
  featureControls = new Map();
  const children = [];
  const links = [];
  for (const group of data.groups || []) {
    const groupFields = data.fields.filter(field => field.group === group.id);
    const groupDiscovered = (data.discovered || []).filter(key => key.group === group.id);
    if (!groupFields.length && !groupDiscovered.length) continue;
    const record = makeFeature(group, groupFields, groupDiscovered);
    featureControls.set(group.id, record);
    children.push(record.section);
    const link = document.createElement('a');
    link.href = `#${record.section.id}`;
    link.textContent = group.label;
    link.dataset.feature = group.id;
    links.push(link);
  }
  fieldsEl.replaceChildren(...children);
  nav.replaceChildren(...links);
}

function render(data) {
  config = data;
  const pathEl = document.querySelector('#settings-config-path');
  if (pathEl && data.config_file) pathEl.textContent = data.config_file;
  controls = new Map();
  touched = new Set();
  renderFeatures(data);
  filterSettings();
  // Sidebar deep-links to Tax & provenance before the async fields exist.
  if (window.location.hash === '#settings-feature-tax') {
    document.getElementById('settings-feature-tax')?.scrollIntoView({block: 'start'});
  }
  document.querySelector('#settings-app-name').textContent = {
    damage: 'DamageBDD', ecai: 'ECAI', nosternity: 'Nosternity', erm: 'ERM', bop: 'BOP'
  }[app];
  document.querySelector('#settings-field-count').textContent = String(data.fields.length);
  document.querySelector('#settings-discovered-count').textContent = `${(data.discovered || []).length} additional keys discovered`;
  document.querySelector('#settings-runtime-status').textContent = data.pending_restart?.length ? 'Restart required' : 'Configuration loaded';
  if (data.last_error) showNotice(`Last reload failed: ${data.last_error}`, 'error');
  updatePending();
}
async function load() {
  setBusy(true);
  try { render(await jsonRequest(api)); }
  catch (error) { showNotice(`Unable to load settings: ${error.message}`, 'error'); }
  finally { setBusy(false); updatePending(); }
}
async function submitMutation(payload, result) {
  setBusy(true);
  clearNotice();
  try {
    await jsonRequest(api, 'POST', { ...payload, version: config.version });
    await load();
    const restarted = config.pending_restart?.length || 0;
    showNotice(restarted ? `${result}. ${restarted} setting(s) need an application/node restart.` : `${result}. Live settings are applied.`, 'info');
  } catch (error) {
    showNotice(error.httpStatus === 409 ? 'The config changed since you opened it. Reload before saving.' : `Save failed: ${error.message}`, 'error');
  } finally { setBusy(false); updatePending(); }
}
async function resetField(name) {
  if (!config || busy) return;
  if (Object.keys(collectChanges()).length &&
      !window.confirm('Resetting will discard unsaved edits. Continue?')) return;
  await submitMutation({ action: 'reset', keys: [name] }, 'Override cleared');
}
function filterSettings() {
  const query = search.value.trim().toLowerCase();
  if (!config) return;
  let visibleFeatures = 0;
  for (const group of config.groups || []) {
    const record = featureControls.get(group.id);
    if (!record) continue;
    const featureMatch = Boolean(query) &&
      `${group.id} ${group.label} ${group.description}`.toLowerCase().includes(query);
    let visible = 0;
    for (const field of config.fields.filter(f => f.group === group.id)) {
      const control = controls.get(field.name);
      if (!control) continue;
      const matches = !query || featureMatch ||
        `${field.name} ${field.label} ${field.source}`.toLowerCase().includes(query);
      control.row.hidden = !matches;
      if (matches) visible++;
    }
    let discoveredVisible = 0;
    for (const key of (config.discovered || []).filter(k => k.group === group.id)) {
      const row = record.discoveredRows.get(key.name);
      const matches = !query || featureMatch || key.name.toLowerCase().includes(query);
      row.hidden = !matches;
      if (matches) discoveredVisible++;
    }
    // A feature is discoverable even when it only contains protected keys.
    const hasContent = visible > 0 || discoveredVisible > 0;
    record.section.hidden = !hasContent;
    if (query && discoveredVisible > 0 && record.details) record.details.open = true;
    const navLink = document.querySelector('#settings-feature-nav a[data-feature="' + group.id + '"]');
    if (navLink) navLink.hidden = !hasContent;
    if (hasContent) visibleFeatures++;
  }
  document.querySelector('#settings-no-results').hidden = visibleFeatures !== 0;
}
search.addEventListener('input', filterSettings);
form.addEventListener('submit', async e => {
  e.preventDefault();
  if (!config || busy) return;
  try {
    const changes = collectChanges();
    if (Object.keys(changes).length) await submitMutation({ action: 'save', changes }, 'Settings persisted to damage.config');
  } catch (error) { showNotice(error.message, 'error'); }
});
discardButton.addEventListener('click', () => { if (config && !busy) { clearNotice(); render(config); } });
refreshButton.addEventListener('click', async () => {
  if (busy) return;
  setBusy(true);
  clearNotice();
  try {
    await jsonRequest('/api/admin/settings/reload', 'POST', {});
    await load();
    showNotice('Configuration reloaded from disk.', 'info');
  } catch (error) { showNotice(`Reload failed: ${error.message}`, 'error'); }
  finally { setBusy(false); updatePending(); }
});
load();
