/* Account-scoped index-artifact policy. This module never signs or mints. */
import {TokenManager} from "/ecai/auth-assets/js/wallet-switcher.js";

(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let generation = 0, readSequence = 0, dirty = false, saving = false, loaded = false;
  let initialized = false;
  const money = value => Number.isSafeInteger(value)
    ? (value / 100).toLocaleString(undefined, {style:'currency', currency:'USD'}) : 'Not available';
  const usdInput = value => Number.isSafeInteger(value) ? (value / 100).toFixed(2) : '0.00';
  function session() { try { return TokenManager.session?.(); } catch (_) { return null; } }
  function token() { try { return TokenManager.getToken?.() || ''; } catch (_) { return ''; } }
  function managed() { return session()?.mode === 'custodial' && Boolean(token()); }
  function message(text, bad = false) {
    const host = $('indexMintSettingsStatus');
    host.textContent = text; host.classList.toggle('is-error', bad);
  }
  function errorText(error) { return String(error?.body?.error || error?.message || 'Request failed').replaceAll('_',' '); }
  function cents(input) {
    const text = String(input).trim();
    if (!/^\d+(?:\.\d{1,2})?$/.test(text)) throw new Error('Enter a non-negative USD amount with at most two decimals.');
    const [whole, fraction = ''] = text.split('.');
    const n = BigInt(whole) * 100n + BigInt(fraction.padEnd(2,'0'));
    if (n > 100000000n) throw new Error('Amount exceeds the accepted limit.');
    return Number(n);
  }
  async function request(path, body) {
    if (!managed()) throw new Error('Sign in with a managed account to change mint preferences.');
    const identity = token(), epoch = generation;
    const response = await fetch(path, {method:body === undefined ? 'GET' : 'POST',
      credentials:'include', mode:'same-origin', redirect:'error', cache:'no-store',
      headers:{Accept:'application/json', Authorization:`Bearer ${identity}`,
        ...(body === undefined ? {} : {'Content-Type':'application/json'})},
      ...(body === undefined ? {} : {body:JSON.stringify(body)})});
    const result = await response.json();
    if (epoch !== generation || identity !== token() || !managed()) throw new DOMException('Session changed','AbortError');
    if (!response.ok || result?.ok !== true) throw Object.assign(new Error(`HTTP ${response.status}`), {body:result});
    return result.data;
  }
  function renderRequests(settings) {
    const host = $('indexMintRequestList'); host.replaceChildren();
    const requests = Array.isArray(settings.mint_requests) ? settings.mint_requests : [];
    if (!requests.length) { const p = document.createElement('p'); p.textContent = 'No mint-review requests. Open a completed index job to check artifact eligibility.'; host.append(p); return; }
    for (const r of requests) {
      const row = document.createElement('article'); row.className = 'index-mint-request';
      const title = document.createElement('strong');
      const details = document.createElement('p');
      const note = document.createElement('small');
      title.textContent = r.requested_metadata?.title || r.metadata?.requested_metadata?.title || `Artifact ${r.job_id || '—'}`;
      details.textContent = `${r.copies || 1} copies · ${String(r.status || 'pending').replaceAll('_',' ')} · total fee cap ${money(r.fee_cap_cents)}`;
      note.textContent = `Job ${r.job_id || '—'} · recipient ${r.recipient || '—'}`;
      row.append(title, details, note); host.append(row);
    }
  }
  async function refresh() {
    if (!initialized || !$('indexMintSettings').open || saving) return;
    const seq = ++readSequence, epoch = generation;
    if (!managed()) { reset(); return; }
    message(dirty ? 'Refreshing request history; unsaved preferences will be kept.' : 'Loading mint preferences…');
    try {
      const settings = await request('/ecai/compute/settings');
      if (seq !== readSequence || epoch !== generation) return;
      if (!settings || typeof settings !== 'object') throw new Error('Mint settings were not returned.');
      renderRequests(settings);
      if (!dirty) {
        const fields = $('indexMintPolicyForm').elements;
        fields.namedItem('enabled').checked = settings.mint?.enabled === true;
        fields.namedItem('recipient').value = settings.mint?.recipient || '';
        fields.namedItem('monthly').value = usdInput(settings.budget?.mint_monthly_cents);
      }
      loaded = true; $('indexMintPolicyFields').disabled = false;
      message(`${money(settings.reserved_mint_cents || 0)} in fee reservations · ${settings.period_utc || '—'} UTC. ${dirty ? 'Unsaved preferences kept.' : 'No transaction is submitted by this review service.'}`);
    } catch (error) {
      if (epoch !== generation || seq !== readSequence || error.name === 'AbortError') return;
      message(errorText(error), true);
      if (!loaded) $('indexMintPolicyFields').disabled = true;
    }
  }
  async function save(event) {
    event.preventDefault();
    const form = $('indexMintPolicyForm');
    if (saving || !loaded || !managed() || !form.reportValidity()) return;
    const epoch = generation;
    try {
      const fields = form.elements;
      const body = {enabled:fields.namedItem('enabled').checked,
        recipient:fields.namedItem('recipient').value.trim(), chain:'aeternity',
        monthly_cents:cents(fields.namedItem('monthly').value)};
      saving = true; ++readSequence; $('indexMintPolicyFields').disabled = true;
      message('Saving mint preferences…');
      // Strict scoped endpoint: never fall back to the legacy full-policy write.
      await request('/ecai/compute/mint-policy', body);
      if (epoch !== generation) return;
      dirty = false; message('Mint preferences saved. Compute limits were not changed.');
    } catch (error) {
      if (epoch === generation && error.name !== 'AbortError') message(errorText(error), true);
    } finally {
      if (epoch === generation) { saving = false; $('indexMintPolicyFields').disabled = !managed() || !loaded; }
    }
  }
  function reset() {
    ++generation; ++readSequence; dirty = false; saving = false; loaded = false;
    $('indexMintPolicyForm').reset(); $('indexMintPolicyFields').disabled = true;
    $('indexMintRequestList').replaceChildren();
    message('Sign in with a managed account to load mint preferences.');
  }
  function open() {
    if (!initialized) return;
    const panel = $('indexMintSettings');
    const wasOpen = panel.open; panel.open = true;
    panel.scrollIntoView({behavior:'smooth', block:'start'});
    panel.querySelector('summary')?.focus({preventScroll:true});
    if (wasOpen) void refresh(); // opening triggers the details toggle otherwise
  }
  function init() {
    if (initialized || !$('indexMintSettings')) return;
    initialized = true;
    $('indexMintSettings').addEventListener('toggle', () => { if ($('indexMintSettings').open) void refresh(); });
    $('indexMintSettingsRefresh').addEventListener('click', () => void refresh());
    $('indexMintPolicyForm').addEventListener('submit', event => void save(event));
    $('indexMintPolicyForm').addEventListener('input', () => { dirty = true; });
    document.addEventListener('ecai:identity-changed', () => {
      reset(); if ($('indexMintSettings').open) void refresh();
    });
  }
  window.EcaiIndexMintSettings = {open, refresh};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
  else init();
})();
