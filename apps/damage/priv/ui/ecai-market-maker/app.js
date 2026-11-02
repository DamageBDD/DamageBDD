/* ECAI market maker dashboard — entirely read-only, no remote chart library. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const finite = n => typeof n === 'number' && Number.isFinite(n);
  const fmt = (n, decimals = 2) => finite(n)
    ? new Intl.NumberFormat('en-US', {maximumFractionDigits: decimals}).format(Number(n)) : '—';
  const money = n => finite(n) ? `${Number(n) < 0 ? '−' : ''}$${fmt(Math.abs(Number(n)), 2)}` : '—';
  const px = n => fmt(n, Number(n) < 0.01 ? 8 : Number(n) < 1 ? 6 : 2);
  const date = t => Number(t) > 0 ? new Date(Number(t)).toLocaleTimeString() : '—';
  const setText = (id, value) => { if ($(id)) $(id).textContent = value; };
  let latest = {status: null, history: [], prices: {rows: []}, cache: null, error: null};
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

  function render(status, history, prices, cache, apiError = null) {
    status = status || {fresh: false, feed_error: apiError || 'engine unavailable', quotes: []};
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
    setText('fees', finite(perf.fees_usdt) ? `$${fmt(perf.fees_usdt, 4)}` : '—');
    $('net-pnl').className = Number(perf.pnl_usdt) > 0 ? 'positive' : Number(perf.pnl_usdt) < 0 ? 'negative' : '';
    const commit = status.audit || {};
    setText('audit-tip', commit.digest_hex ? String(commit.digest_hex).substring(0, 36) + '…' : 'Awaiting first market observation');
    setText('event-count', `${fmt(status.events, 0)} chained events • P-256`);
    showQuotes(working ? status.quotes || [] : []);
    showFills(perf.fills || []);
    const ticks = (Array.isArray(history) ? history : []).filter(row => finite(row.damage_index) && finite(row.btc_index) && finite(row.equity_usdt) && finite(row.ts_ms));
    const historical = (Array.isArray(prices?.rows) ? prices.rows : [])
      .filter(row => finite(row.ts_ms) && finite(row.damage_index) && finite(row.btc_index));
    // Do not splice order-book mids into candle closes or historical candles
    // into the paper equity timeline. Each chart has a single clear provenance.
    const market = historical.length ? historical : ticks;
    setText('market-source', historical.length
      ? `Coinstore ${prices.period} closed candles · indexed to 100 at first shared timestamp · ${prices.missing_intervals || 0} missing intervals (not filled)`
      : 'Live engine observations only · historical candles not yet available');
    const allSeries = Array.isArray(cache?.series) ? cache.series : [];
    const stored = allSeries.reduce((n, row) => n + (finite(row.count) ? row.count : 0), 0);
    const errors = allSeries.filter(row => row.last_error).map(row => `${row.symbol}/${row.period}: ${row.last_error}`);
    const cacheMessage = cache?.available === true
      ? `${fmt(stored,0)} stored closed candles · ${historical.length} aligned chart points · ${cache.queued || 0} queued backfill requests. Historical data is not a live order book.${errors.length ? ' Backfill: ' + errors.join('; ') : ''}`
      : 'Persistent price cache unavailable. Live engine observations, when available, remain separate.';
    setText('cache-state', cacheMessage);
    drawPlot('market-chart', 'market-empty', market,
      [{key: 'damage_index', color: '#6be9ae'}, {key: 'btc_index', color: '#75a7fd'}], n => fmt(n, 1),
      historical.length ? prices.period_ms * 1.5 : null);
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

  function drawPlot(canvasId, emptyId, series, lines, valueLabel, maxGapMs = null) {
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
    const values = data.flatMap(p=>lines.map(l=>p[l.key])).filter(finite);
    if(!values.length)return;
    let min = Math.min(...values), max = Math.max(...values);
    const padding = Math.max((max-min)*0.15,Math.abs(max)*0.002,0.01);min -= padding;max += padding;
    const margin={left:63,right:15,top:9,bottom:26};
    const W=width-margin.left-margin.right,H=height-margin.top-margin.bottom;
    if(W<15||H<15)return;
    const firstTs=data[0].ts_ms,lastTs=data[data.length-1].ts_ms;
    const x=i=>margin.left+(data[i].ts_ms-firstTs)/Math.max(1,lastTs-firstTs)*W;
    const y=v=>margin.top+H-(v-min)/(max-min)*H;
    ctx.font='11px ui-sans-serif,system-ui';ctx.textBaseline='middle';
    for(let i=0;i<=4;i++){
      const v=min+(max-min)*i/4,Y=y(v);
      ctx.strokeStyle='#29384a';ctx.lineWidth=1;ctx.setLineDash([3,5]);ctx.beginPath();ctx.moveTo(margin.left,Y);ctx.lineTo(width-margin.right,Y);ctx.stroke();
      ctx.setLineDash([]);ctx.fillStyle='#95a6bd';ctx.textAlign='right';ctx.fillText(valueLabel(v),margin.left-9,Y);
    }
    const stamp=t=>new Date(t).toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
    const start=stamp(firstTs),end=stamp(lastTs);
    ctx.fillStyle='#91a2bb';ctx.textBaseline='alphabetic';
    ctx.textAlign='left';ctx.fillText(start,margin.left,height-4);
    ctx.textAlign='right';ctx.fillText(end,width-margin.right,height-4);
    for(const line of lines){
      ctx.beginPath();let begun=false;
      data.forEach((row,i)=>{
        const v=row[line.key];
        if(!finite(v)){begun=false;return;}
        if(i && finite(maxGapMs) && row.ts_ms-data[i-1].ts_ms>maxGapMs)begun=false;
        const X=x(i),Y=y(v);if(!begun){ctx.moveTo(X,Y);begun=true;}else ctx.lineTo(X,Y);
      });
      ctx.strokeStyle=line.color;ctx.lineWidth=2.2;ctx.lineJoin='round';ctx.lineCap='round';ctx.setLineDash([]);ctx.stroke();
      const last=data[data.length-1][line.key];
      if(finite(last)){ctx.beginPath();ctx.arc(x(data.length-1),y(last),3.2,0,Math.PI*2);ctx.fillStyle=line.color;ctx.fill();}
    }
  }

  async function refresh() {
    if(inFlight)return;inFlight=true;
    const period=$('history-period').value;
    try {
      const [status, history, prices, cache] = await Promise.allSettled([
        json('/api/ecai/mm/status'), json('/api/ecai/mm/history?limit=1000'),
        json(`/api/ecai/mm/prices?period=${encodeURIComponent(period)}&limit=2000`),
        json('/api/ecai/mm/price-cache')
      ]);
      if(period!==$('history-period').value)return;
      // A failed live API must not leave the previous green LIVE badge or quotes
      // on screen. Historical reads can still succeed while the engine is off.
      latest={
        status:status.status==='fulfilled'?status.value:null,
        history:history.status==='fulfilled'?history.value:latest.history,
        prices:prices.status==='fulfilled'?prices.value:{rows:[]},
        cache:cache.status==='fulfilled'?cache.value:null,
        error:status.status==='rejected'?status.reason.message:null
      };
      render(latest.status, latest.history, latest.prices, latest.cache, latest.error);
    } finally {
      inFlight=false;
      if(period!==$('history-period').value)refresh();
    }
  }
  $('history-period').addEventListener('change',()=>{
    latest.prices={rows:[]};
    render(latest.status,latest.history,latest.prices,latest.cache,latest.error);
    refresh();
  });
  window.addEventListener('resize',()=>render(latest.status,latest.history,latest.prices,latest.cache,latest.error));
  refresh();setInterval(refresh,10000);
})();
