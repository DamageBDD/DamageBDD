/* ECAI market maker dashboard — entirely read-only, no remote chart library. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const fmt = (n, decimals = 2) => Number.isFinite(Number(n))
    ? new Intl.NumberFormat('en-US', {maximumFractionDigits: decimals}).format(Number(n)) : '—';
  const money = n => Number.isFinite(Number(n)) ? `${Number(n) < 0 ? '−' : ''}$${fmt(Math.abs(Number(n)), 2)}` : '—';
  const px = n => fmt(n, Number(n) < 0.01 ? 8 : Number(n) < 1 ? 6 : 2);
  const date = t => Number(t) > 0 ? new Date(Number(t)).toLocaleTimeString() : '—';
  const setText = (id, value) => { if ($(id)) $(id).textContent = value; };
  const finite = n => typeof n === 'number' && Number.isFinite(n);
  let latest = {status: null, history: []};
  let inFlight = false;

  async function json(url) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 7000);
    try {
      const r = await fetch(url, {cache: 'no-store', credentials: 'same-origin', signal: controller.signal});
      if (!r.ok) throw new Error(`API HTTP ${r.status}`);
      return await r.json();
    } finally { clearTimeout(timer); }
  }

  function render(status, history) {
    const p = status.price && typeof status.price === 'object' ? status.price : {};
    const perf = status.performance || {};
    const age = status.feed_age_ms;
    const fresh = status.fresh === true;
    const working = fresh && !status.paused;
    const indicator = $('feed-state');
    indicator.textContent = !fresh ? 'FEED UNAVAILABLE' : status.paused ? 'PAUSED' : 'FEED LIVE';
    indicator.className = `chip ${working ? 'online' : 'offline'}`;
    setText('last-updated', Number.isFinite(age) ? `${(age / 1000).toFixed(0)}s old · ${date(p.fetched_ms)}` : 'No quote received');
    const banner = $('banner');
    if (!fresh) {
      banner.className = 'banner error';
      banner.textContent = `Quote generation disabled: stale or unavailable Coinstore feed (${String(status.feed_error || 'no data')}).`;
    } else if (status.paused) {
      banner.className = 'banner error';
      banner.textContent = `Quote generation stopped by risk control: ${status.halt_reason}. Inspect risk before resuming from the Erlang console.`;
    } else {
      banner.className = 'banner good';
      const ref = p.reference_deviation_bps;
      banner.textContent = `Coinstore order book healthy • Volatility ${fmt(p.volatility_bps, 1)} bps • ${status.quotes?.length || 0} paper quotes • Price-feed reference ${finite(ref) ? `${fmt(ref,1)} bps deviation` : 'unavailable'}. No live orders are submitted.`;
    }
    setText('damage-price', finite(p.mid) ? `$${px(p.mid)}` : '—');
    setText('btc-price', finite(p.btc_usdt) ? `$${px(p.btc_usdt)}` : '—');
    setText('net-pnl', finite(perf.equity_usdt) ? money(perf.pnl_usdt) : '—');
    setText('return-pct', finite(perf.equity_usdt) ? `${fmt(perf.pnl_pct, 2)}% return (paper)` : 'Since initial mark');
    setText('equity', money(perf.equity_usdt));
    const holdings = perf.balances || {};
    const exposure = Number(perf.equity_usdt) > 0 ? (Number(holdings.damage) * Number(p.mid) / Number(perf.equity_usdt)) * 100 : null;
    setText('inventory-ratio', Number.isFinite(exposure) ? `${fmt(exposure, 1)}% DAMAGE inventory` : 'Marked to DAMAGE mid');
    setText('drawdown', finite(perf.equity_usdt) ? `${fmt(perf.max_drawdown_pct,2)}%` : '—');
    setText('fees', `$${fmt(perf.fees_usdt, 4)}`);
    $('net-pnl').className = Number(perf.pnl_usdt) > 0 ? 'positive' : Number(perf.pnl_usdt) < 0 ? 'negative' : '';
    const commit = status.audit || {};
    setText('audit-tip', commit.digest_hex ? String(commit.digest_hex).substring(0, 36) + '…' : 'Awaiting first market observation');
    setText('event-count', `${fmt(status.events, 0)} chained events • P-256`);
    showQuotes(status.quotes || []);
    showFills(perf.fills || []);
    const ticks = (Array.isArray(history) ? history : []).filter(row => finite(row.damage_index) && finite(row.btc_index) && finite(row.equity_usdt) && finite(row.ts_ms));
    drawPlot('market-chart', 'market-empty', ticks,
      [{key: 'damage_index', color: '#6be9ae'}, {key: 'btc_index', color: '#75a7fd'}], n => fmt(n, 1));
    const initial = perf.opening_equity_usdt;
    const equityTicks = ticks.map(t => ({...t, btc_bench_equity: Number(initial) + Number(t.btc_benchmark_pnl_usdt)}));
    drawPlot('pnl-chart', 'pnl-empty', equityTicks,
      [{key: 'equity_usdt', color: '#6be9ae'}, {key: 'btc_bench_equity', color: '#f4c97a'}], n => '$' + fmt(n, 1));
  }

  function showQuotes(rows) {
    setText('quote-count', `${rows.length} QUOTES`);
    table('quotes-table', rows, q => [
      cell(String(q.side).toUpperCase(), String(q.side).toLowerCase()),
      cell(String(q.level)), cell(px(q.price), 'right'),
      cell(fmt(q.remaining_qty, 4), 'right'),
      cell('$' + fmt(Number(q.remaining_qty) * Number(q.price),2), 'right')
    ], 'No funded active paper quotes');
  }
  function showFills(rows) {
    setText('fill-count', `${rows.length} RECENT FILLS`);
    table('fills-table', rows.slice().reverse(), f => [
      cell(date(f.ts_ms)), cell(String(f.side).toUpperCase(), String(f.side).toLowerCase()),
      cell(px(f.price),'right'), cell(fmt(f.qty,4),'right'), cell('$'+fmt(f.fee_usdt,4),'right')
    ], 'No confirmed paper fills');
  }
  function cell(value, klass='') {const c = document.createElement('td');c.textContent=value;c.className=klass;return c;}
  function table(id, rows, cells, empty) {
    const body = $(id);body.replaceChildren();
    if (!rows.length) {const row=document.createElement('tr');const td=cell(empty,'placeholder');td.colSpan=5;row.appendChild(td);body.appendChild(row);return;}
    for(const value of rows){const tr=document.createElement('tr');for(const td of cells(value))tr.appendChild(td);body.appendChild(tr);}
  }

  function drawPlot(canvasId, emptyId, series, lines, valueLabel) {
    const canvas = $(canvasId);
    $(emptyId).classList.toggle('hide', series.length >= 2);
    const ctx = canvas.getContext('2d');
    const width = Math.max(1, canvas.clientWidth);
    const height = Math.max(1, canvas.clientHeight);
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
    ctx.setTransform(ratio,0,0,ratio,0,0);ctx.clearRect(0,0,width,height);
    if(series.length < 2) return;
    const data = series.slice(-1000);
    const values = data.flatMap(p=>lines.map(l=>Number(p[l.key]))).filter(Number.isFinite);
    if(!values.length)return;
    let min = Math.min(...values), max = Math.max(...values);
    const padding = Math.max((max-min)*0.15,Math.abs(max)*0.002,0.01);min -= padding;max += padding;
    const margin={left:63,right:15,top:9,bottom:26};
    const W=width-margin.left-margin.right,H=height-margin.top-margin.bottom;
    if(W<15||H<15)return;
    const x=i=>margin.left+(i/(data.length-1))*W;
    const y=v=>margin.top+H-(v-min)/(max-min)*H;
    ctx.font='11px ui-sans-serif,system-ui';ctx.textBaseline='middle';
    for(let i=0;i<=4;i++){
      const v=min+(max-min)*i/4,Y=y(v);
      ctx.strokeStyle='#29384a';ctx.lineWidth=1;ctx.setLineDash([3,5]);ctx.beginPath();ctx.moveTo(margin.left,Y);ctx.lineTo(width-margin.right,Y);ctx.stroke();
      ctx.setLineDash([]);ctx.fillStyle='#95a6bd';ctx.textAlign='right';ctx.fillText(valueLabel(v),margin.left-9,Y);
    }
    const start=date(data[0].ts_ms),end=date(data[data.length-1].ts_ms);
    ctx.fillStyle='#91a2bb';ctx.textBaseline='alphabetic';
    ctx.textAlign='left';ctx.fillText(start,margin.left,height-4);
    ctx.textAlign='right';ctx.fillText(end,width-margin.right,height-4);
    for(const line of lines){
      ctx.beginPath();let begun=false;
      data.forEach((row,i)=>{const v=Number(row[line.key]);if(!Number.isFinite(v))return;const X=x(i),Y=y(v);if(!begun){ctx.moveTo(X,Y);begun=true;}else ctx.lineTo(X,Y);});
      ctx.strokeStyle=line.color;ctx.lineWidth=2.2;ctx.lineJoin='round';ctx.lineCap='round';ctx.setLineDash([]);ctx.stroke();
      const last=Number(data[data.length-1][line.key]);
      if(Number.isFinite(last)){ctx.beginPath();ctx.arc(x(data.length-1),y(last),3.2,0,Math.PI*2);ctx.fillStyle=line.color;ctx.fill();}
    }
  }

  async function refresh() {
    if(inFlight)return;inFlight=true;
    try {
      const [status, history] = await Promise.all([
        json('/api/ecai/mm/status'),json('/api/ecai/mm/history?limit=1000')
      ]);
      latest={status,history};render(status,history);
    } catch(e) {
      const chip=$('feed-state');chip.textContent='API DISCONNECTED';chip.className='chip offline';
      const banner=$('banner');banner.className='banner error';banner.textContent=`Dashboard API unavailable (${e.message}). Ensure the worker is started and the authenticated Cowboy routes are mounted.`;
    } finally {inFlight=false;}
  }
  window.addEventListener('resize',()=>{if(latest.status)render(latest.status,latest.history);});
  refresh();setInterval(refresh,10000);
})();
