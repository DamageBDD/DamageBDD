/* Dedicated tax-only settings editor. The server, not the browser, enforces
 * node_admin/tax_admin authorization and the seven-field mutation allowlist.
 * No API credentials or other node settings are exposed here.
 */
const SETTINGS_URL = '/api/node/tax/settings';
export const TAX_KEYS = Object.freeze([
  'tax_enabled', 'tax_cln_owner', 'tax_data_dir', 'tax_backfill_on_start',
  'tax_standard_utc_offset_minutes', 'tax_max_prices_per_backfill', 'tax_price_pause_ms'
]);
const TAX_SET = new Set(TAX_KEYS);
const AE_ACCOUNT = /^ak_[1-9A-HJ-NP-Za-km-z]{13,125}$/;

export function allowedTaxFields(fields) {
  if (!Array.isArray(fields)) return [];
  const seen = new Set();
  return fields.filter(f => {
    if (!f || typeof f !== 'object' || !TAX_SET.has(f.name) || seen.has(f.name)) return false;
    if (!['boolean', 'integer', 'ae_account', 'absolute_path'].includes(f.type)) return false;
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
  const input = document.createElement('input');
  input.id = id;
  input.name = field.name;
  if (field.type === 'boolean') {
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
  if (!response.ok) throw Error(typeof data.error === 'string' ? data.error : `HTTP ${response.status}`);
  return data;
}

export function initDashboardTaxSettings() {
  if (typeof document === 'undefined') return null;
  const form = document.getElementById('tax-settings-form');
  if (!form) return null;
  const fieldsRoot = document.getElementById('tax-settings-fields');
  const status = document.getElementById('tax-settings-status');
  const restart = document.getElementById('tax-settings-restart');
  const save = document.getElementById('tax-settings-save');
  const discard = document.getElementById('tax-settings-discard');
  const reload = document.getElementById('tax-settings-refresh');
  let current = null;
  let controls = new Map();
  let busy = false;

  function notice(message) { status.textContent = message; }
  function setBusy(value) {
    busy = value;
    save.disabled = value;
    discard.disabled = value;
    reload.disabled = value;
    for (const input of controls.values()) input.disabled = value;
  }
  function updateDirty() {
    if (!current || busy) return;
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
    setBusy(true);
    try { display(await request()); }
    catch (error) { notice(`Could not load tax settings: ${error.message}`); }
    finally { setBusy(false); save.disabled = true; discard.disabled = true; }
  }
  reload.addEventListener('click', () => void refresh());
  discard.addEventListener('click', () => { if (current) display(current); });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!current || busy) return;
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
    setBusy(true);
    try {
      const updated = await request('POST', {action: 'save', version: current.version, changes});
      display(updated);
      notice((updated.restart_required === true || (updated.pending_restart || []).length > 0) ?
        'Tax settings saved. Restart DamageBDD to apply lifecycle changes.' :
        'Tax settings saved. Hot settings apply to subsequent runs.');
    } catch (error) {
      notice(`Tax settings not saved: ${error.message}`);
      if (error.message === 'config_changed_reload_required') notice('Configuration changed elsewhere; reload settings and retry.');
    } finally { setBusy(false); if (current) updateDirty(); }
  });
  void refresh();
  return {refresh};
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initDashboardTaxSettings, {once: true});
  } else {
    initDashboardTaxSettings();
  }
}
