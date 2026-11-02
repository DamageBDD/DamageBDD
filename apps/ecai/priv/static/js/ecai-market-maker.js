/* ECAI Market Maker control plane. Same-origin, node-admin only, paper execution.
   No mocked chart points, inferred fills, browser-held exchange keys or remote JS. */
export function initMarketMaker({request, canManage, openLogin}) {
  const $ = (id) => document.getElementById(id);
  const root = document.querySelector('[data-panel="market-maker"]');
  if (!root) return {setVisible(){}, refresh(){}, reset(){}, accessChanged(){}, dispose(){}};
  const state = {visible: false, tab: 'monitor', status: null, history: [], config: null,
    requestSerial: 0, fetching: false, lastHistory: 0, busy: false, timer: null};
  const fields = Array.from($('mmConfigForm').querySelectorAll('input[name]'));
  const percentFields = new Set(fields.filter((e) => e.dataset.mmPercent === 'true').map((e) => e.name));
  const fmt = (v, precision = 2) => Number.isFinite(v) ? Number(v).toLocaleString(undefined,
    {maximumFractionDigits: precision}) : '—';
  const money = (v, precision = 2) => Number.isFinite(v) ? `${v < 0 ? '−' : ''}${fmt(Math.abs(v), precision)} USDT` : '—';
  const when = (ts) => Number.isFinite(ts) && ts > 0 ? new Date(ts).toLocaleTimeString() : '—';
  const notice = (msg, isError = false) => {
    const node = $('mmNotice'); node.textContent = msg;
    node.classList.toggle('mm-notice-error', isError);
  };
  const errorText = (e) => {
    if (e?.status === 403) return 'Market Maker requires a managed node-admin account and market_maker_admin_enabled=true.';
    if (e?.status === 503) return 'Market maker is offline or not enabled. Check ecai_mm supervision and server configuration.';
    if (e?.status === 409) return 'The state changed on the server. Reload configuration before saving again.';
    return e?.message || 'Market Maker request failed.';
  };

  function accessChanged() {
    const permitted = canManage();
    $('mmConfigFields').disabled = !permitted || !state.config || state.busy;
    $('mmRefresh').disabled = !permitted;
    $('mmPoll').disabled = !permitted || !state.status || state.busy;
    $('mmVerify').disabled = !permitted || !state.status || state.busy;
    $('mmPause').disabled = !permitted || !state.status || state.status.paused || state.busy;
    $('mmResume').disabled = !permitted || !state.status || !state.status.paused || state.busy;
    if (!permitted) {
      notice('This control requires an authenticated DamageBDD node-admin account. Wallet-only sign-in is read-only.');
    }
  }

  function selectTab(which, focus = false) {
    if (!['monitor', 'configure', 'performance', 'audit'].includes(which)) which = 'monitor';
    state.tab = which;
    for (const button of root.querySelectorAll('[data-mm-tab]')) {
      const active = button.dataset.mmTab === which;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
      if (focus && active) button.focus();
    }
    for (const panel of root.querySelectorAll('[data-mm-section]')) {
      panel.hidden = panel.dataset.mmSection !== which;
    }
    if (which === 'configure' && !state.config && canManage()) void loadConfig();
  }

  function rows(target, values, build, colspan) {
    const host = $(target); host.replaceChildren();
    if (!values.length) {
      const row = document.createElement('tr');
      const cell = document.createElement('td');
      cell.colSpan = colspan; cell.className = 'empty-cell'; cell.textContent = 'No entries available';
      row.append(cell); host.append(row); return;
    }
    for (const entry of values) {
      const row = document.createElement('tr');
      for (const value of build(entry)) {
        const cell = document.createElement('td'); cell.textContent = String(value);
        row.append(cell);
      }
      host.append(row);
    }
  }

  function drawChart(id, series, labels) {
    const host = $(id); host.replaceChildren();
    const entries = series.filter((s) => s.points.some((p) => Number.isFinite(p)));
    const n = Math.max(0, ...entries.map((s) => s.points.length));
    if (!entries.length || !n) {
      const empty = document.createElement('div'); empty.className = 'empty-state';
      empty.textContent = 'No real observations for this chart yet.';
      host.append(empty); return;
    }
    const all = entries.flatMap((s) => s.points).filter(Number.isFinite);
    let low = Math.min(...all), high = Math.max(...all);
    if (low === high) { low -= Math.max(0.01, Math.abs(low) * 0.002); high += Math.max(0.01, Math.abs(high) * 0.002); }
    const pad = (high - low) * 0.12; low -= pad; high += pad;
    const w = 960, h = 265, left = 66, right = 18, top = 14, bottom = 39;
    const x = (i) => left + i * (w - left - right) / Math.max(1, n - 1);
    const y = (v) => top + (high - v) * (h - top - bottom) / (high - low);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
    svg.setAttribute('role', 'presentation');
    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    const el = (tag, attrs, text = '') => {
      const node = document.createElementNS(ns, tag);
      for (const [key, val] of Object.entries(attrs)) node.setAttribute(key, String(val));
      if (text) node.textContent = text;
      svg.append(node); return node;
    };
    for (let j = 0; j <= 4; j++) {
      const value = low + j * (high - low) / 4;
      const yy = y(value);
      el('line', {x1: left, y1: yy, x2: w - right, y2: yy, class: 'mm-grid-line'});
      el('text', {x: left - 9, y: yy + 4, 'text-anchor': 'end', class: 'mm-axis-text'}, fmt(value, 2));
    }
    el('text', {x: left, y: h - 12, class: 'mm-axis-text'}, labels[0] || 'First');
    el('text', {x: w - right, y: h - 12, 'text-anchor': 'end', class: 'mm-axis-text'}, labels[1] || 'Latest');
    for (const serie of entries) {
      const segments = []; let segment = [];
      for (let i = 0; i < serie.points.length; i++) {
        const v = serie.points[i];
        if (!Number.isFinite(v)) {
          if (segment.length) segments.push(segment);
          segment = []; continue;
        }
        segment.push(`${segment.length ? 'L' : 'M'} ${x(i).toFixed(2)} ${y(v).toFixed(2)}`);
      }
      if (segment.length) segments.push(segment);
      for (const commands of segments) el('path', {d: commands.join(' '), fill: 'none',
        stroke: serie.color, 'stroke-width': 2.6, 'stroke-linecap': 'round',
        'stroke-linejoin': 'round'});
      if (serie.points.length === 1 && Number.isFinite(serie.points[0]))
        el('circle', {cx: x(0), cy: y(serie.points[0]), r: 4, fill: serie.color});
    }
    host.append(svg);
  }

  function renderMarket() {
    const s = state.status;
    if (!s) return;
    const price = s.price && typeof s.price === 'object' ? s.price : {};
    const p = s.performance || {};
    const balances = p.balances || {};
    const mid = price.mid;
    const age = s.feed_age_ms;
    $('mmMode').textContent = s.mode === 'paper' ? 'PAPER ONLY · EXCHANGE TRADING DISABLED' : 'UNSUPPORTED ENGINE MODE';
    $('mmFeedState').textContent = s.fresh ? 'Feed healthy' : 'Feed stale / unavailable';
    $('mmFeedDot').classList.toggle('is-good', !!s.fresh);
    $('mmFeedDot').classList.toggle('is-bad', !s.fresh);
    $('mmEngineState').textContent = s.paused ? `Paused (${s.halt_reason || 'manual'})` : s.fresh ? 'Quoting · paper' : 'Waiting for feed';
    $('mmLastObservation').textContent = when(price.fetched_ms);
    $('mmLastRefresh').textContent = new Date().toLocaleTimeString();
    $('mmDamagePrice').textContent = Number.isFinite(mid) ? `$${fmt(mid, 8)}` : '—';
    $('mmBtcPrice').textContent = Number.isFinite(price.btc_usdt) ? `$${fmt(price.btc_usdt)}` : '—';
    $('mmMarketSpread').textContent = Number.isFinite(price.bid) && Number.isFinite(price.ask) && mid > 0
      ? `${fmt(10000 * (price.ask - price.bid) / mid, 1)} bps` : '—';
    $('mmQuoteCount').textContent = fmt(s.quotes?.length || 0);
    $('mmInventoryRatio').textContent = Number.isFinite(p.equity_usdt) && p.equity_usdt > 0
      ? `${fmt(100 * (balances.damage || 0) * mid / p.equity_usdt, 1)}%` : '—';
    $('mmVolatility').textContent = Number.isFinite(price.volatility_bps) ? `${fmt(price.volatility_bps, 2)} bps` : '—';
    $('mmEquity').textContent = money(p.equity_usdt);
    $('mmPnl').textContent = money(p.pnl_usdt);
    $('mmPnlPct').textContent = Number.isFinite(p.pnl_pct) ? `${fmt(p.pnl_pct, 2)}% vs opening equity` : '—';
    $('mmDrawdownStat').textContent = Number.isFinite(p.max_drawdown_pct) ? `${fmt(p.max_drawdown_pct, 2)}%` : '—';
    $('mmFees').textContent = money(p.fees_usdt, 4);
    $('mmTurnover').textContent = money(p.turnover_usdt);
    $('mmFillCount').textContent = fmt(p.fill_count || 0);
    $('mmHaltReason').textContent = s.halt_reason || 'none';
    $('mmFeedAge').textContent = Number.isFinite(age) ? `${fmt(age / 1000, 1)} s` : 'Unknown';
    $('mmFeedErrors').textContent = s.feed_error || 'none';
    $('mmQuoteStamp').textContent = s.fresh ? `${fmt(s.quotes?.length || 0)} paper orders` : 'No fresh quotes';
    $('mmEventCount').textContent = fmt(s.events || 0);
    $('mmAuditHash').textContent = s.audit?.digest_hex || '—';
    $('mmStatePoint').textContent = s.audit?.state_point_hex || '—';
    const quotes = Array.isArray(s.quotes) ? s.quotes : [];
    const renderQuote = (q) => [fmt(q.price, 8), fmt(q.remaining_qty, 4), money(q.price * q.remaining_qty)];
    rows('mmBids', quotes.filter((q) => q.side === 'buy'), renderQuote, 3);
    rows('mmAsks', quotes.filter((q) => q.side === 'sell'), renderQuote, 3);
    rows('mmFills', Array.isArray(p.fills) ? [...p.fills].reverse().slice(0, 50) : [],
      (f) => [when(f.ts_ms), f.side || '—', fmt(f.qty, 4), fmt(f.price, 8), money(f.notional_usdt), money(f.fee_usdt, 4)], 6);
    accessChanged();
  }

  function renderHistory() {
    const points = state.history.filter((e) => Number.isFinite(e.ts_ms) &&
      Number.isFinite(e.damage_usdt) && Number.isFinite(e.btc_usdt));
    const first = points.length ? when(points[0].ts_ms) : '—';
    const last = points.length ? when(points[points.length - 1].ts_ms) : '—';
    drawChart('mmPriceChart', [
      {color: 'var(--theme-info, #5266e7)', points: points.map((p) => p.damage_index)},
      {color: 'var(--theme-success, #14a88e)', points: points.map((p) => p.btc_index)}], [first, last]);
    const opening = state.status?.performance?.opening_equity_usdt;
    drawChart('mmPerformanceChart', [
      {color: 'var(--theme-info, #5266e7)', points: points.map((p) => p.equity_usdt)},
      {color: 'var(--theme-warning, #e49b4f)', points: points.map((p) => Number.isFinite(opening)
        ? opening + p.btc_benchmark_pnl_usdt : NaN)}], [first, last]);
    $('mmSampleCount').textContent = `${fmt(points.length)} stored market observations in the selected window. Charts show observed data only.`;
    const events = state.history.filter((e) => e.audit_hash);
    rows('mmEvents', events.slice(-35).reverse(), (e) => [when(e.ts_ms), e.type || 'tick',
      String(e.audit_hash).slice(0, 28) + '…'], 3);
  }

  function loadFields(values) {
    for (const input of fields) {
      const value = values[input.name];
      input.value = Number.isFinite(value) ? String(percentFields.has(input.name) ? value * 100 : value) : '';
    }
    $('mmConfigRevision').textContent = `Revision ${state.config?.revision ?? '—'}`;
    $('mmConfigNotice').textContent = 'Current server configuration loaded. Changes require explicit Save.';
    accessChanged();
  }
  function dirty() {
    if (!state.config) return false;
    return fields.some((input) => {
      const value = Number(input.value);
      const actual = percentFields.has(input.name) ? value / 100 : value;
      return !Number.isFinite(actual) || Math.abs(actual - state.config.values[input.name]) > 1e-9;
    });
  }
  async function loadConfig(force = false) {
    if (!canManage() || (state.busy && !force)) return;
    const res = await request('/ecai/mm/config');
    if (!state.visible || !canManage()) return;
    if (!force && dirty()) {
      $('mmConfigNotice').textContent = 'Configuration changed on the server. Discard local edits before reloading.';
      return;
    }
    state.config = res.config;
    if (state.config?.mode !== 'paper' || state.config?.execution_enabled !== false)
      throw new Error('Unsupported trading mode; controls remain disabled.');
    loadFields(state.config.values || {});
  }

  async function refresh(full = false) {
    if (!state.visible || !canManage() || state.fetching) { accessChanged(); return; }
    const serial = state.requestSerial;
    state.fetching = true;
    try {
      const res = await request('/ecai/mm/status');
      if (serial !== state.requestSerial || !state.visible || !canManage()) return;
      state.status = res.status;
      notice(state.status.fresh ? 'Live Coinstore observations · paper strategy running. No real trades will be submitted.' :
        `Paper engine has no fresh quotes: ${state.status.feed_error || state.status.halt_reason || 'feed not ready'}.`, !state.status.fresh);
      renderMarket();
      const now = Date.now();
      if (full || now - state.lastHistory >= 11000) {
        const hist = await request('/ecai/mm/history?limit=800');
        if (serial !== state.requestSerial || !state.visible || !canManage()) return;
        state.history = Array.isArray(hist.history) ? hist.history : [];
        state.lastHistory = Date.now();
        renderHistory();
      }
      if (!state.config || (!dirty() && state.config.revision !== state.status.config_revision))
        await loadConfig();
      else if (state.config?.revision !== state.status.config_revision)
        $('mmConfigNotice').textContent = 'Server configuration revision changed. Discard edits and reload before saving.';
    } catch (e) {
      if (serial === state.requestSerial) notice(errorText(e), true);
    } finally { state.fetching = false; accessChanged(); }
  }

  async function runBusy(action, onDone) {
    if (state.busy || !canManage()) { if (!canManage()) openLogin('Node-admin managed sign-in required'); return; }
    state.busy = true; accessChanged();
    try { await action(); if (onDone) onDone(); }
    catch (e) { notice(errorText(e), true); }
    finally { state.busy = false; accessChanged(); }
  }

  async function saveConfig(event) {
    event.preventDefault();
    if (!canManage() || !state.config || !event.currentTarget.reportValidity()) return;
    const changes = {};
    for (const input of fields) {
      const n = Number(input.value);
      if (!input.value.trim() || !Number.isFinite(n)) return;
      const value = percentFields.has(input.name) ? n / 100 : n;
      if (Math.abs(value - state.config.values[input.name]) > 1e-9) changes[input.name] = value;
    }
    if (!Object.keys(changes).length) {
      $('mmConfigNotice').textContent = 'No changes to apply.'; return;
    }
    if (!window.confirm('Apply new PAPER strategy parameters? This will invalidate the current paper quotes and request a fresh market observation.')) return;
    await runBusy(async () => {
      const res = await request('/ecai/mm/config', {method: 'POST',
        body: {expected_revision: state.config.revision, changes}});
      state.config = res.config;
      loadFields(state.config.values);
      $('mmConfigNotice').textContent = `Saved revision ${state.config.revision}. Awaiting a fresh quote cycle.`;
      notice('Paper configuration saved and persisted. Live exchange execution remains disabled.');
    }, () => { void refresh(true); });
  }

  async function control(action) {
    if ((action === 'pause' || action === 'resume') && !window.confirm(
      action === 'pause' ? 'Pause market maker PAPER quoting?' : 'Resume market maker PAPER quoting if risk limits allow?')) return;
    await runBusy(async () => {
      await request('/ecai/mm/control', {method: 'POST', body: {action}});
      notice(action === 'poll' ? 'Fresh Coinstore poll requested.' : `Paper quoting ${action === 'pause' ? 'paused' : 'resumed'}.`);
    }, () => { void refresh(true); });
  }
  async function verify() {
    await runBusy(async () => {
      const result = await request('/ecai/mm/audit');
      $('mmVerifyResult').textContent = result.verified ?
        'Retained hash-chain and P-256 commitments verified against local persisted tip. Export the tip independently for tamper-evidence.' :
        'Audit verification failed.';
    });
  }
  function setVisible(visible) {
    state.visible = !!visible;
    clearInterval(state.timer); state.timer = null;
    if (state.visible) {
      accessChanged();
      state.timer = setInterval(() => {
        if (!document.hidden) void refresh();
      }, 4000);
    }
  }
  function reset() {
    state.requestSerial++;
    state.status = null; state.config = null; state.history = [];
    state.lastHistory = 0;
    for (const id of ['mmPriceChart', 'mmPerformanceChart']) $(id).replaceChildren();
    for (const id of ['mmBids', 'mmAsks', 'mmFills', 'mmEvents']) $(id).replaceChildren();
    for (const id of [
      'mmDamagePrice', 'mmBtcPrice', 'mmMarketSpread', 'mmQuoteCount',
      'mmInventoryRatio', 'mmVolatility', 'mmEquity', 'mmPnl', 'mmPnlPct',
      'mmDrawdownStat', 'mmFees', 'mmTurnover', 'mmFillCount', 'mmHaltReason',
      'mmFeedAge', 'mmFeedErrors', 'mmEventCount', 'mmAuditHash', 'mmStatePoint',
      'mmFeedState', 'mmEngineState', 'mmLastObservation', 'mmLastRefresh',
      'mmQuoteStamp', 'mmSampleCount', 'mmVerifyResult', 'mmConfigNotice'
    ]) $(id).textContent = '—';
    $('mmFeedDot').classList.remove('is-good', 'is-bad');
    for (const input of fields) input.value = '';
    $('mmConfigRevision').textContent = 'Revision —';
    accessChanged();
  }
  function dispose() { clearInterval(state.timer); state.timer = null; }

  root.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-mm-tab]');
    if (btn) selectTab(btn.dataset.mmTab);
  });
  root.querySelector('.mm-tabs').addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return;
    const tabs = ['monitor', 'configure', 'performance', 'audit'];
    const step = event.key === 'ArrowRight' ? 1 : -1;
    selectTab(tabs[(tabs.indexOf(state.tab) + step + tabs.length) % tabs.length], true);
    event.preventDefault();
  });
  $('mmRefresh').addEventListener('click', () => void refresh(true));
  $('mmConfigForm').addEventListener('submit', saveConfig);
  $('mmResetConfig').addEventListener('click', () => {
    void loadConfig(true).catch((e) => notice(errorText(e), true));
  });
  $('mmPause').addEventListener('click', () => void control('pause'));
  $('mmResume').addEventListener('click', () => void control('resume'));
  $('mmPoll').addEventListener('click', () => void control('poll'));
  $('mmVerify').addEventListener('click', () => void verify());
  accessChanged(); selectTab('monitor');
  return {setVisible, refresh, reset, accessChanged, dispose};
}
