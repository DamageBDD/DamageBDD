// Account settings and node-context controls. No account secrets are persisted in browser storage.
(() => {
  const $ = (id) => document.getElementById(id);
  const root = document.querySelector('.account-settings');
  if (!root || root.dataset.bound === 'true') return;
  root.dataset.bound = 'true';

  const redacted = 'XX-REDACTED-XX';
  const accountStatus = $('account-settings-status');
  const domainStatus = $('domain-settings-status');
  const webhookStatus = $('webhook-settings-status');
  const securityStatus = $('account-security-status');

  function setStatus(el, message, tone) {
    if (!el) return;
    el.textContent = message || '';
    el.className = 'workspace-status';
    if (el === accountStatus) el.classList.add('account-settings-notice');
    if (tone) el.dataset.tone = tone;
    else delete el.dataset.tone;
  }

  function authHeaders(json = false, browserAuth = false) {
    const headers = new Headers({Accept: 'application/json'});
    const token = window.TokenManager?.getToken?.();
    if (token) headers.set('Authorization', `Bearer ${token}`);
    if (json) headers.set('Content-Type', 'application/json');
    if (browserAuth) headers.set('X-Damage-Auth', '1');
    return headers;
  }

  async function api(url, options = {}) {
    const headers = authHeaders(Boolean(options.body), Boolean(options.browserAuth));
    for (const [key, value] of new Headers(options.headers || {}).entries()) headers.set(key, value);
    const response = await fetch(url, {
      credentials: 'include',
      cache: 'no-store',
      mode: 'same-origin',
      redirect: 'error',
      ...options,
      headers
    });
    const text = await response.text();
    let body = {};
    if (text) {
      try { body = JSON.parse(text); }
      catch (_) { body = {message: text}; }
    }
    if (!response.ok) {
      const message = body?.message || body?.reason || body?.error || `Request failed (${response.status})`;
      const error = new Error(typeof message === 'string' ? message : JSON.stringify(message));
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  }

  function session() {
    return window.TokenManager?.session?.() || null;
  }

  function formatExpiry(unix) {
    if (!Number.isFinite(Number(unix))) return '—';
    const date = new Date(Number(unix) * 1000);
    if (Number.isNaN(date.getTime())) return '—';
    return date.toLocaleString();
  }

  function formatAtomic(entry) {
    if (!entry || entry.available !== true) return 'Unavailable';
    if (entry.amount_sat != null) return `${entry.amount_sat} sat`;
    const raw = String(entry.amount ?? '0');
    if (!/^\d+$/.test(raw)) return raw;
    const decimals = Math.max(0, Number(entry.decimals || 0));
    if (decimals === 0) return `${raw} ${entry.symbol || ''}`.trim();
    const padded = raw.padStart(decimals + 1, '0');
    const whole = padded.slice(0, -decimals);
    const fraction = padded.slice(-decimals).replace(/0+$/, '').slice(0, 8);
    return `${fraction ? `${whole}.${fraction}` : whole} ${entry.symbol || ''}`.trim();
  }

  function renderSession() {
    const s = session();
    const address = s?.address || window.TokenManager?.getAddress?.() || null;
    const email = s?.email || window.TokenManager?.getEmail?.() || null;
    const mode = s?.mode || null;
    $('account-settings-email').textContent = email || (mode === 'wallet' ? 'Wallet-authenticated' : '—');
    $('account-settings-address').textContent = address || '—';
    $('account-settings-expiry').textContent = formatExpiry(s?.expires_at);
    $('account-settings-mode').textContent = mode === 'wallet' ? 'Wallet signature' : mode === 'custodial' ? 'Managed email session' : '—';
    const badge = $('account-auth-badge');
    badge.textContent = mode === 'wallet' ? 'wallet session' : mode === 'custodial' ? 'managed session' : 'not signed in';
    badge.dataset.tone = s ? 'success' : 'warning';

    const recovery = $('account-password-recovery');
    if (recovery) {
      const allowed = mode === 'custodial' && typeof email === 'string' && email.includes('@');
      recovery.disabled = !allowed;
      recovery.title = allowed ? '' : 'Password recovery is only available for managed email sessions.';
    }
    renderCapabilities(s?.capabilities || {});
  }

  function renderCapabilities(capabilities) {
    const list = $('account-capabilities');
    if (!list) return;
    list.replaceChildren();
    const labels = {
      account_context: 'Account context',
      schedules: 'Schedules',
      nwc: 'NWC',
      execution: 'Execution',
      billing: 'Billing'
    };
    const keys = Object.keys(capabilities).filter((key) => typeof capabilities[key] === 'boolean').sort();
    if (!keys.length) {
      const empty = document.createElement('span');
      empty.className = 'workspace-muted';
      empty.textContent = 'No capability metadata is available for this session.';
      list.appendChild(empty);
      return;
    }
    for (const key of keys) {
      const pill = document.createElement('span');
      pill.className = 'account-capability';
      pill.dataset.enabled = String(capabilities[key] === true);
      pill.textContent = `${labels[key] || key.replaceAll('_', ' ')} · ${capabilities[key] ? 'enabled' : 'restricted'}`;
      list.appendChild(pill);
    }
  }

  async function loadWallet() {
    const badge = $('account-wallet-status');
    badge.textContent = 'Loading…';
    delete badge.dataset.tone;
    try {
      const data = await api('/accounts/wallet');
      const balances = data?.balances || {};
      $('account-balance-damage').textContent = formatAtomic(balances.damage);
      $('account-balance-ae').textContent = formatAtomic(balances.ae);
      $('account-balance-sats').textContent = formatAtomic(balances.lightning);
      $('account-nwc-count').textContent = String(balances.lightning?.session_count ?? 0);
      badge.textContent = data?.status === 'ok' ? 'current' : 'partial';
      badge.dataset.tone = data?.status === 'ok' ? 'success' : 'warning';
    } catch (error) {
      badge.textContent = 'unavailable';
      badge.dataset.tone = 'warning';
      $('account-balance-damage').textContent = '—';
      $('account-balance-ae').textContent = '—';
      $('account-balance-sats').textContent = '—';
      $('account-nwc-count').textContent = '—';
      throw error;
    }
  }

  async function refreshAccount() {
    renderSession();
    setStatus(accountStatus, 'Refreshing account…');
    try {
      await loadWallet();
      if (window.TokenManager?.can?.('account_context')) {
        await Promise.allSettled([loadDomains(), loadWebhooks()]);
      } else {
        renderUnavailableAutomation();
      }
      setStatus(accountStatus, '');
    } catch (error) {
      setStatus(accountStatus, error.message, 'error');
    }
  }

  function renderUnavailableAutomation() {
    const reason = window.TokenManager?.capabilities?.()?.reason || 'This session cannot manage account automation.';
    for (const [listId, statusEl] of [['domain-settings-list', domainStatus], ['webhook-settings-list', webhookStatus]]) {
      const list = $(listId);
      if (list) {
        list.replaceChildren();
        const empty = document.createElement('div');
        empty.className = 'account-list-empty';
        empty.textContent = reason;
        list.appendChild(empty);
      }
      setStatus(statusEl, '');
    }
  }

  async function copyText(value, button) {
    if (!value) return;
    try {
      await navigator.clipboard.writeText(value);
      const previous = button?.textContent;
      if (button) button.textContent = 'Copied';
      setTimeout(() => { if (button && previous) button.textContent = previous; }, 1200);
    } catch (_) {
      window.prompt('Copy this value:', value);
    }
  }

  function safeWebhookLabel(raw) {
    try {
      const url = new URL(raw);
      return `${url.origin}${url.pathname}${url.search ? '?…' : ''}`;
    } catch (_) {
      return 'Configured endpoint';
    }
  }

  function expiryLabel(unix) {
    const date = new Date(Number(unix) * 1000);
    return Number.isNaN(date.getTime()) ? 'Expiry unavailable' : `Expires ${date.toLocaleDateString()}`;
  }

  function domainItems(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return [];
    return Object.entries(payload).map(([id, value]) => ({id, ...(value || {})}));
  }

  function renderDomains(payload) {
    const list = $('domain-settings-list');
    list.replaceChildren();
    const items = domainItems(payload).sort((a, b) => String(a.domain || '').localeCompare(String(b.domain || '')));
    if (!items.length) {
      const empty = document.createElement('div');
      empty.className = 'account-list-empty';
      empty.textContent = 'No authorized domains yet.';
      list.appendChild(empty);
      return;
    }
    for (const item of items) {
      const row = document.createElement('div');
      row.className = 'account-list-row';
      const copy = document.createElement('div');
      copy.className = 'account-list-copy';
      const name = document.createElement('strong');
      name.textContent = item.domain || item.id;
      const meta = document.createElement('span');
      meta.textContent = expiryLabel(item.expiry);
      copy.append(name, meta);
      const actions = document.createElement('div');
      actions.className = 'account-row-actions';
      const txt = `damagebdd_token=${item.domain_token || ''}`;
      const copyButton = document.createElement('button');
      copyButton.type = 'button'; copyButton.className = 'workspace-button'; copyButton.textContent = 'Copy TXT';
      copyButton.addEventListener('click', () => copyText(txt, copyButton));
      const remove = document.createElement('button');
      remove.type = 'button'; remove.className = 'workspace-button workspace-danger'; remove.textContent = 'Remove';
      remove.addEventListener('click', () => deleteDomain(item.id));
      actions.append(copyButton, remove);
      row.append(copy, actions);
      list.appendChild(row);
    }
  }

  async function loadDomains() {
    if (!window.TokenManager?.can?.('account_context')) return;
    setStatus(domainStatus, 'Loading domains…');
    try {
      const payload = await api('/domains');
      renderDomains(payload);
      setStatus(domainStatus, '');
    } catch (error) {
      setStatus(domainStatus, error.message, 'error');
    }
  }

  async function createDomain(event) {
    event.preventDefault();
    const input = $('domain-settings-host');
    const domain = input.value.trim().toLowerCase();
    if (!domain) return;
    setStatus(domainStatus, `Creating verification token for ${domain}…`);
    try {
      const result = await api('/domains', {method: 'POST', body: JSON.stringify({domain})});
      const record = `damagebdd_token=${result.domain_token || ''}`;
      $('domain-token-record').textContent = record;
      $('domain-token-result').hidden = false;
      $('domain-token-copy').onclick = () => copyText(record, $('domain-token-copy'));
      input.value = '';
      setStatus(domainStatus, 'Token ready. Publish the TXT record, then DNS verification can authorize this domain.', 'success');
      await loadDomains();
    } catch (error) {
      setStatus(domainStatus, error.message, 'error');
    }
  }

  async function deleteDomain(id) {
    if (!id || !window.confirm('Remove this domain authorization?')) return;
    setStatus(domainStatus, 'Removing domain…');
    try {
      await api(`/domains/${encodeURIComponent(id)}`, {method: 'DELETE'});
      $('domain-token-result').hidden = true;
      await loadDomains();
      setStatus(domainStatus, 'Domain authorization removed.', 'success');
    } catch (error) {
      setStatus(domainStatus, error.message, 'error');
    }
  }

  function renderWebhooks(payload) {
    const list = $('webhook-settings-list');
    list.replaceChildren();
    const items = payload && typeof payload === 'object' && !Array.isArray(payload) ? Object.entries(payload) : [];
    items.sort(([a], [b]) => a.localeCompare(b));
    if (!items.length) {
      const empty = document.createElement('div');
      empty.className = 'account-list-empty';
      empty.textContent = 'No webhooks configured.';
      list.appendChild(empty);
      return;
    }
    for (const [nameValue, url] of items) {
      const row = document.createElement('div');
      row.className = 'account-list-row';
      const copy = document.createElement('div');
      copy.className = 'account-list-copy';
      const name = document.createElement('strong'); name.textContent = nameValue;
      const meta = document.createElement('span'); meta.textContent = safeWebhookLabel(String(url || ''));
      copy.append(name, meta);
      const remove = document.createElement('button');
      remove.type = 'button'; remove.className = 'workspace-button workspace-danger'; remove.textContent = 'Remove';
      remove.addEventListener('click', () => deleteWebhook(nameValue));
      row.append(copy, remove);
      list.appendChild(row);
    }
  }

  async function loadWebhooks() {
    if (!window.TokenManager?.can?.('account_context')) return;
    setStatus(webhookStatus, 'Loading webhooks…');
    try {
      const payload = await api('/webhooks');
      renderWebhooks(payload);
      setStatus(webhookStatus, '');
    } catch (error) {
      setStatus(webhookStatus, error.message, 'error');
    }
  }

  async function createWebhook(event) {
    event.preventDefault();
    const name = $('webhook-name').value.trim();
    const url = $('webhook-url').value.trim();
    if (!name || !url) return;
    setStatus(webhookStatus, `Saving ${name}…`);
    try {
      await api('/webhooks', {method: 'POST', body: JSON.stringify({name, url})});
      event.currentTarget.reset();
      await loadWebhooks();
      setStatus(webhookStatus, `${name} saved.`, 'success');
    } catch (error) {
      setStatus(webhookStatus, error.message, 'error');
    }
  }

  async function deleteWebhook(name) {
    if (!name || !window.confirm(`Remove webhook "${name}"?`)) return;
    setStatus(webhookStatus, `Removing ${name}…`);
    try {
      await api(`/webhooks/${encodeURIComponent(name)}`, {method: 'DELETE'});
      await loadWebhooks();
      setStatus(webhookStatus, `${name} removed.`, 'success');
    } catch (error) {
      setStatus(webhookStatus, error.message, 'error');
    }
  }

  async function requestPasswordRecovery() {
    const email = session()?.email;
    if (!email) return;
    setStatus(securityStatus, 'Requesting password reset email…');
    try {
      const result = await api('/accounts/recovery', {
        method: 'POST', browserAuth: true, body: JSON.stringify({email})
      });
      setStatus(securityStatus, result?.message || 'Password reset email requested.', 'success');
    } catch (error) {
      setStatus(securityStatus, error.message, 'error');
    }
  }

  async function refreshSession() {
    setStatus(accountStatus, 'Refreshing browser session…');
    try {
      await window.TokenManager?.refreshSession?.();
      await refreshAccount();
    } catch (error) {
      setStatus(accountStatus, error.message, 'error');
    }
  }

  function bindAccountUi() {
    $('account-settings-refresh')?.addEventListener('click', refreshAccount);
    $('account-session-refresh')?.addEventListener('click', refreshSession);
    $('account-copy-address')?.addEventListener('click', (event) => copyText(window.TokenManager?.getAddress?.(), event.currentTarget));
    $('account-password-recovery')?.addEventListener('click', requestPasswordRecovery);
    $('account-open-wallet')?.addEventListener('click', () => $('open-wallet-modal-btn')?.click());
    $('account-manage-nwc')?.addEventListener('click', () => $('open-nwc-modal-btn')?.click());
    $('account-sign-out')?.addEventListener('click', () => $('logoutBtn')?.click());
    $('domain-settings-form')?.addEventListener('submit', createDomain);
    $('webhook-settings-form')?.addEventListener('submit', createWebhook);
    document.addEventListener('auth:changed', () => refreshAccount());
    document.addEventListener('damage:panelchange', (event) => {
      if (event.detail?.id === 'settings-tab') refreshAccount();
    });
  }

  // The node-context editor is isolated in the server-rendered node-admin panel.
  // Its endpoints enforce node_admin on every request, regardless of UI state.
  function bindNodeContext() {
    const nodeRoot = $('node-context-settings');
    if (!nodeRoot || nodeRoot.dataset.bound === 'true') return;
    nodeRoot.dataset.bound = 'true';
    const endpoint = '/node/context';
    const rows = $('node-context-rows');
    const versionEl = $('node-context-version');
    const rootEl = $('node-context-root');
    const statusEl = $('node-context-status');
    const editor = $('node-context-editor');
    const nameEl = $('node-context-name');
    const valueEl = $('node-context-value');
    const typeEl = $('node-context-type');
    const sensitiveEl = $('node-context-sensitive');
    const exposureEl = $('node-context-exposure');
    const inheritanceEl = $('node-context-inheritance');
    let currentVersion = null;
    let currentEntries = {};

    function nodeStatus(message, tone) { setStatus(statusEl, message, tone); }
    function displayValue(entry) {
      if (!entry) return '';
      if (entry.sensitive === true || entry.value === redacted) return redacted;
      if (typeof entry.value === 'string') return entry.value;
      return JSON.stringify(entry.value);
    }
    function addCell(row, value, useCode = false) {
      const td = document.createElement('td');
      const child = useCode ? document.createElement('code') : document.createTextNode(value == null ? '' : String(value));
      if (useCode) child.textContent = value == null ? '' : String(value);
      td.appendChild(child); row.appendChild(td); return td;
    }
    function renderEntries() {
      rows.replaceChildren();
      const names = Object.keys(currentEntries).sort();
      if (!names.length) {
        const row = document.createElement('tr'); const td = document.createElement('td'); td.colSpan = 7;
        td.textContent = 'No node context variables configured.'; row.appendChild(td); rows.appendChild(row); return;
      }
      for (const name of names) {
        const entry = currentEntries[name] || {}; const row = document.createElement('tr');
        addCell(row, name, true); addCell(row, displayValue(entry), true);
        addCell(row, entry.sensitive === true ? 'yes' : 'no'); addCell(row, entry.exposure || '');
        addCell(row, entry.inheritance || ''); addCell(row, entry.locked === true ? 'yes' : 'no');
        const actions = document.createElement('td'); actions.className = 'account-row-actions';
        const edit = document.createElement('button'); edit.type = 'button'; edit.className = 'workspace-button'; edit.textContent = 'Edit';
        edit.addEventListener('click', () => editEntry(name, entry));
        const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'workspace-button workspace-danger'; remove.textContent = 'Delete';
        remove.addEventListener('click', () => deleteEntry(name)); actions.append(edit, remove); row.appendChild(actions); rows.appendChild(row);
      }
    }
    async function loadContext() {
      nodeStatus('Loading node context…');
      try {
        const data = await api(endpoint);
        currentVersion = Number.isInteger(data.version) ? data.version : null;
        currentEntries = data.entries && typeof data.entries === 'object' ? data.entries : {};
        versionEl.textContent = currentVersion === null ? '—' : String(currentVersion);
        rootEl.textContent = data.root || '—'; renderEntries(); nodeStatus('');
      } catch (error) {
        rows.replaceChildren(); const row = document.createElement('tr'); const td = document.createElement('td'); td.colSpan = 7;
        td.textContent = 'Unable to load node context.'; row.appendChild(td); rows.appendChild(row); nodeStatus(error.message, 'error');
      }
    }
    function inferType(value) {
      if (typeof value === 'boolean') return 'boolean'; if (Number.isInteger(value)) return 'integer';
      if (typeof value === 'number') return 'float'; if (value !== null && typeof value === 'object') return 'json'; return 'string';
    }
    function editEntry(name, entry) {
      nameEl.value = name; nameEl.readOnly = true; sensitiveEl.checked = entry.sensitive === true;
      exposureEl.value = entry.exposure || 'template'; inheritanceEl.value = entry.inheritance || 'default';
      if (entry.value === redacted || entry.sensitive === true) {
        valueEl.value = ''; valueEl.placeholder = 'Enter a replacement value for this sensitive setting'; typeEl.value = 'string';
      } else {
        typeEl.value = inferType(entry.value); valueEl.value = typeEl.value === 'json' ? JSON.stringify(entry.value, null, 2) : String(entry.value ?? '');
        valueEl.placeholder = '';
      }
      nodeRoot.querySelector('.account-context-editor-wrap').open = true; valueEl.focus();
    }
    function clearEditor() { editor.reset(); nameEl.readOnly = false; valueEl.placeholder = 'https://api.example.com'; }
    function typedValue() {
      const raw = valueEl.value;
      switch (typeEl.value) {
        case 'integer': if (!/^-?\d+$/.test(raw.trim())) throw new Error('Value must be an integer.'); return Number.parseInt(raw, 10);
        case 'float': { const value = Number(raw); if (!Number.isFinite(value)) throw new Error('Value must be a number.'); return value; }
        case 'boolean': if (raw.trim().toLowerCase() === 'true') return true; if (raw.trim().toLowerCase() === 'false') return false; throw new Error('Boolean value must be "true" or "false".');
        case 'json': return JSON.parse(raw);
        default: return raw;
      }
    }
    async function saveEntry(event) {
      event.preventDefault(); const name = nameEl.value.trim(); if (!name) return nodeStatus('Name is required.', 'error');
      let value; try { value = typedValue(); } catch (error) { return nodeStatus(error.message, 'error'); }
      const payload = {set: {[name]: {value, sensitive: sensitiveEl.checked, exposure: exposureEl.value, inheritance: inheritanceEl.value}}, delete: []};
      if (currentVersion !== null) payload.expected_version = currentVersion;
      nodeStatus(`Saving ${name}…`);
      try { await api(endpoint, {method: 'PATCH', body: JSON.stringify(payload)}); clearEditor(); await loadContext(); nodeStatus(`${name} saved.`, 'success'); }
      catch (error) { if (error.status === 409) { nodeStatus('Node context changed elsewhere. Reloading latest version…', 'error'); await loadContext(); } else nodeStatus(error.message, 'error'); }
    }
    async function deleteEntry(name) {
      if (!window.confirm(`Delete node context "${name}"?`)) return;
      const payload = {set: {}, delete: [name]}; if (currentVersion !== null) payload.expected_version = currentVersion;
      nodeStatus(`Deleting ${name}…`);
      try { await api(endpoint, {method: 'PATCH', body: JSON.stringify(payload)}); if (nameEl.value === name) clearEditor(); await loadContext(); nodeStatus(`${name} deleted.`, 'success'); }
      catch (error) { if (error.status === 409) { nodeStatus('Node context changed elsewhere. Reloading latest version…', 'error'); await loadContext(); } else nodeStatus(error.message, 'error'); }
    }
    editor.addEventListener('submit', saveEntry);
    $('node-context-refresh')?.addEventListener('click', loadContext);
    $('node-context-cancel')?.addEventListener('click', clearEditor);
    document.addEventListener('damage:panelchange', (event) => {
      if (event.detail?.id === 'node-context-tab') void loadContext();
    });
    if (!$('node-context-tab')?.hidden) void loadContext();
  }

  bindAccountUi();
  bindNodeContext();
  renderSession();
  refreshAccount();
})();
