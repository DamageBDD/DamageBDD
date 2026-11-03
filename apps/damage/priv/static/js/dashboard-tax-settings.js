/* Dedicated tax-only settings editor. The server, not the browser, enforces
 * node_admin/tax_admin authorization and the tax-only mutation allowlist.
 * No API credentials or other node settings are exposed here.
 */
const SETTINGS_URL = '/api/node/tax/settings';
export const TAX_KEYS = Object.freeze([
  'tax_enabled', 'tax_cln_owner', 'tax_data_dir', 'tax_backfill_on_start',
  'tax_jurisdiction', 'tax_standard_utc_offset_minutes', 'tax_max_prices_per_backfill', 'tax_price_pause_ms'
]);
const TAX_SET = new Set(TAX_KEYS);
const AE_ACCOUNT = /^ak_[1-9A-HJ-NP-Za-km-z]{13,125}$/;
const editors = new WeakMap();

export function allowedTaxFields(fields) {
  if (!Array.isArray(fields)) return [];
  const seen = new Set();
  return fields.filter(f => {
    if (!f || typeof f !== 'object' || !TAX_SET.has(f.name) || seen.has(f.name)) return false;
    if (!['boolean', 'integer', 'ae_account', 'absolute_path', 'tax_jurisdiction'].includes(f.type)) return false;
    seen.add(f.name);
    return true;
  }).sort((a, b) => TAX_KEYS.indexOf(a.name) - TAX_KEYS.indexOf(b.name));
}

export function readTaxControl(field, input) {
  if (field.type === 'boolean') return input.checked === true;
  const text = String(input.value || '').trim();
  if (field.type === 'integer') {
    if (!/^[0-9]+$/.test(text)) throw Error(`${field.label}: enter an integer`);
    const n = Number(text);
    if (!Number.isSafeInteger(n) || n < field.min || n > field.max) {
      throw Error(`${field.label}: enter a number from ${field.min} to ${field.max}`);
    }
    return n;
  }
  if (field.type === 'tax_jurisdiction') {
    if (!Array.isArray(field.options) || !field.options.some(o => o.value === text)) {
      throw Error('Select a supported tax reporting country');
    }
    return text;
  }
  if (field.type === 'ae_account') {
    if (!AE_ACCOUNT.test(text)) throw Error(`${field.label}: enter a valid ak_ account`);
    return text;
  }
  if (field.type === 'absolute_path') {
    if (!text.startsWith('/') || text.includes('\0') || text.includes('..')) {
      throw Error(`${field.label}: enter a dedicated absolute directory`);
    }
    return text;
  }
  throw Error('Unsupported tax field');
}

export function changedTaxSettings(fields, controls) {
  const changes = {};
  for (const field of allowedTaxFields(fields)) {
    const input = controls.get(field.name);
    if (!input) continue;
    const original = field.value;
    const value = field.type === 'boolean' ? input.checked === true :
      field.type === 'integer' && original !== null ? Number(input.value) :
      input.value.trim();
    if (value !== original && !(original == null && value === '')) {
      changes[field.name] = readTaxControl(field, input);
    }
  }
  return changes;
}

function makeField(field) {
  const card = document.createElement('div');
  card.className = 'tax-settings-field';
  const label = document.createElement('label');
  label.textContent = field.label;
  const id = `tax-setting-${field.name}`;
  label.htmlFor = id;
  const input = document.createElement(field.type === 'tax_jurisdiction' ? 'select' : 'input');
  input.id = id;
  input.name = field.name;
  if (field.type === 'tax_jurisdiction') {
    for (const option of (field.options || [])) {
      const el = document.createElement('option');
      el.value = option.value;
      el.textContent = option.label;
      input.appendChild(el);
    }
    input.value = field.value ?? 'AU';
  } else if (field.type === 'boolean') {
    input.type = 'checkbox';
    input.checked = field.value === true;
  } else if (field.type === 'integer') {
    input.type = 'number';
    input.min = String(field.min);
    input.max = String(field.max);
    input.step = '1';
    input.value = field.value == null ? '' : String(field.value);
  } else {
    input.type = 'text';
    input.value = field.value == null ? '' : String(field.value);
    input.maxLength = field.type === 'ae_account' ? 128 : 512;
    input.autocomplete = 'off';
    input.spellcheck = false;
  }
  const help = document.createElement('small');
  help.textContent = `${field.apply === 'restart' ? 'Restart required. ' : 'Live for next run. '}${field.help || ''}`;
  card.append(label, input, help);
  return {card, input};
}

async function request(method = 'GET', payload = null) {
  const headers = {Accept: 'application/json'};
  if (method !== 'GET') {
    headers['Content-Type'] = 'application/json';
    headers['X-Damage-Tax-Request'] = '1';
  }
  const response = await fetch(SETTINGS_URL, {
    method, credentials: 'same-origin', cache: 'no-store', headers,
    ...(payload !== null ? {body: JSON.stringify(payload)} : {})
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = Error(typeof data.error === 'string' ? data.error : `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function loadFailure(error) {
  if (error.status === 401 || error.status === 403) {
    return 'Tax settings access is not authorised. Sign in with an approved administrator account, then select Reload settings.';
  }
  if (error.status === 503 || error.message === 'tax_settings_unavailable') {
    return 'The node settings service is unavailable. Ask the node administrator to check its configuration and service logs, then select Reload settings.';
  }
  return 'Could not load tax settings. Check the connection and node settings service, then select Reload settings. Editing remains unavailable until a fresh read succeeds.';
}

export function initDashboardTaxSettings() {
  if (typeof document === 'undefined') return null;
  const form = document.getElementById('tax-settings-form');
  if (!form) return null;
  if (editors.has(form)) return editors.get(form);
  const panel = form.closest('[data-dashboard-view]');
  const fieldsRoot = document.getElementById('tax-settings-fields');
  const status = document.getElementById('tax-settings-status');
  const restart = document.getElementById('tax-settings-restart');
  const save = document.getElementById('tax-settings-save');
  const discard = document.getElementById('tax-settings-discard');
  const reload = document.getElementById('tax-settings-refresh');
  let current = null;
  let controls = new Map();
  let busy = false;
  let available = false;
  let attempted = false;
  let authEpoch = 0;

  function notice(message) { status.textContent = message; }
  function setBusy(value) {
    busy = value;
    save.disabled = value || !available;
    discard.disabled = value || !available;
    reload.disabled = value;
    for (const input of controls.values()) input.disabled = value || !available;
  }
  function updateDirty() {
    if (!current || busy || !available) return;
    try {
      const changes = changedTaxSettings(current.fields, controls);
      const dirty = Object.keys(changes).length > 0;
      save.disabled = !dirty;
      discard.disabled = !dirty;
      if (dirty) notice(`${Object.keys(changes).length} unsaved tax setting(s)`);
    } catch (error) {
      save.disabled = true;
      discard.disabled = false;
      notice(error.message);
    }
  }
  function display(data) {
    if (typeof data.version !== 'string' || !Array.isArray(data.fields)) {
      throw Error('invalid_tax_settings_response');
    }
    const fields = allowedTaxFields(data.fields);
    if (fields.length !== TAX_KEYS.length) throw Error('incomplete_tax_settings_response');
    current = {...data, fields};
    available = true;
    controls = new Map();
    const cards = [];
    for (const field of fields) {
      const {card, input} = makeField(field);
      controls.set(field.name, input);
      input.addEventListener('input', updateDirty);
      input.addEventListener('change', updateDirty);
      cards.push(card);
    }
    fieldsRoot.replaceChildren(...cards);
    const pending = Array.isArray(data.pending_restart) ? data.pending_restart : [];
    restart.hidden = pending.length === 0;
    restart.textContent = pending.length ?
      `Saved changes require a node restart: ${pending.map(k => String(k).replace(/^damage\./, '')).join(', ')}` : '';
    notice(`Tax settings loaded. Tax service is ${data.running === true ? 'running' : 'not running'}.`);
    save.disabled = true;
    discard.disabled = true;
  }
  async function refresh() {
    if (busy) return;
    const epoch = authEpoch;
    attempted = true;
    available = false;
    setBusy(true);
    try {
      const data = await request();
      if (epoch === authEpoch) display(data);
    } catch (error) {
      if (epoch === authEpoch) { available = false; notice(loadFailure(error)); }
    } finally {
      if (epoch === authEpoch) { setBusy(false); save.disabled = true; discard.disabled = true; }
    }
  }
  reload.addEventListener('click', () => void refresh());
  discard.addEventListener('click', () => { if (current && available && !busy) display(current); });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!current || busy || !available) return;
    let changes;
    try {
      changes = changedTaxSettings(current.fields, controls);
      if (!Object.keys(changes).length) return;
      const enabled = Object.hasOwn(changes, 'tax_enabled') ? changes.tax_enabled :
        controls.get('tax_enabled').checked;
      const owner = Object.hasOwn(changes, 'tax_cln_owner') ? changes.tax_cln_owner :
        controls.get('tax_cln_owner').value.trim();
      if (enabled && !AE_ACCOUNT.test(owner)) throw Error('Set a valid CLN tax owner before enabling reporting');
    } catch (error) { notice(error.message); return; }
    const epoch = authEpoch;
    setBusy(true);
    let failure = null;
    try {
      const updated = await request('POST', {action: 'save', version: current.version, changes});
      if (epoch !== authEpoch) return;
      display(updated);
      notice((updated.restart_required === true || (updated.pending_restart || []).length > 0) ?
        'Tax settings saved. Restart DamageBDD to apply lifecycle changes.' :
        'Tax settings saved. Hot settings apply to subsequent runs.');
    } catch (error) {
      if (epoch !== authEpoch) return;
      if (!error.status || error.status >= 500 || [401, 403, 409].includes(error.status)) available = false;
      failure = error.message === 'config_changed_reload_required' ?
        'Configuration changed elsewhere; select Reload settings before editing again.' :
        !available ? 'Save was not confirmed. Reload settings to check the recorded values before trying again.' :
        `Tax settings not saved: ${error.message}`;
    } finally {
      if (epoch === authEpoch) {
        setBusy(false);
        if (current) updateDirty();
        if (failure) notice(failure);
      }
    }
  });
  function activate() {
    if (!attempted && !form.closest('[hidden]') && !document.hidden) void refresh();
  }
  if (panel) {
    document.addEventListener('damage:panelchange', event => {
      if (event.detail?.id === panel.id) activate();
    });
    new MutationObserver(activate).observe(panel, {attributes: true, attributeFilter: ['hidden']});
  }
  document.addEventListener('visibilitychange', activate);
  document.addEventListener('auth:changed', () => {
    // Retire reads and writes from the previous session, including their
    // finally handlers, before starting a new session's request.
    authEpoch++;
    current = null;
    controls = new Map();
    available = false;
    attempted = false;
    fieldsRoot.replaceChildren();
    restart.hidden = true;
    restart.textContent = '';
    setBusy(false);
    notice('Open this section to load tax settings.');
    activate();
  });
  setBusy(false);
  notice('Open this section to load tax settings.');
  const editor = {refresh};
  editors.set(form, editor);
  activate();
  return editor;
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initDashboardTaxSettings, {once: true});
  } else {
    initDashboardTaxSettings();
  }
}
