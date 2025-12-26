  // === Config ===
  const MDW = "https://mainnet.aeternity.io/mdw/v3";

  // Put your real contracts here (or fetch them from your own config endpoint):
  const CONTRACT_ID_RUNS = "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk";     // emits Run/Result events
  // Optional: token contract etc
  // const CONTRACT_ID_DAMAGE = "ct_YOUR_DAMAGE_TOKEN_CONTRACT_ID";

  // How many logs to pull (MDW is paginated; start with a chunk and iterate if you need more)
  const LOG_LIMIT = 10;

  // === Helpers ===
  async function fetchJson(url) {
    const res = await fetch(url, { headers: { "accept": "application/json" } });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
    return await res.json();
  }

  function isoDay(tsMs) {
    const d = new Date(tsMs);
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth() + 1).padStart(2, "0");
    const day = String(d.getUTCDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  // MDW log rows differ slightly by version/deployment; try common time fields.
  function pickTimestampMs(row) {
    // common candidates seen across MDW deployments:
    // - row.micro_time (µs) or row.time (ms/sec) or row.block_time (sec)
    if (row.micro_time != null) {
      const v = Number(row.micro_time);
      return v > 1e14 ? Math.floor(v / 1000) : v; // if already ms, keep
    }
    if (row.time != null) {
      const v = Number(row.time);
      return v > 1e12 ? v : v * 1000; // if seconds -> ms
    }
    if (row.block_time != null) return Number(row.block_time) * 1000;
    // fall back: now
    return Date.now();
  }

  function drawLineChart(canvas, series, opts = {}) {
    // series: [{name, values:[{xLabel, y}], stroke}]
    const ctx = canvas.getContext("2d");
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);

    const pad = { l: 40, r: 10, t: 10, b: 28 };
    const plotW = W - pad.l - pad.r;
    const plotH = H - pad.t - pad.b;

    const labels = series[0]?.values.map(v => v.xLabel) ?? [];
    const allY = series.flatMap(s => s.values.map(v => v.y));
    const yMax = Math.max(1, ...allY);
    const yMin = 0;

    // Axes
    ctx.strokeStyle = "rgba(0,0,0,0.15)";
    ctx.beginPath();
    ctx.moveTo(pad.l, pad.t);
    ctx.lineTo(pad.l, pad.t + plotH);
    ctx.lineTo(pad.l + plotW, pad.t + plotH);
    ctx.stroke();

    // Y ticks
    ctx.fillStyle = "rgba(0,0,0,0.6)";
    ctx.font = "12px system-ui, sans-serif";
    const ticks = 4;
    for (let i = 0; i <= ticks; i++) {
      const y = yMax * (i / ticks);
      const py = pad.t + plotH - (y / yMax) * plotH;
      ctx.strokeStyle = "rgba(0,0,0,0.08)";
      ctx.beginPath();
      ctx.moveTo(pad.l, py);
      ctx.lineTo(pad.l + plotW, py);
      ctx.stroke();
      ctx.fillText(String(Math.round(y)), 6, py + 4);
    }

    // X tick labels (sparse)
    const stride = Math.max(1, Math.floor(labels.length / 6));
    labels.forEach((lab, i) => {
      if (i % stride !== 0 && i !== labels.length - 1) return;
      const px = pad.l + (i / Math.max(1, labels.length - 1)) * plotW;
      ctx.fillStyle = "rgba(0,0,0,0.5)";
      ctx.fillText(lab.slice(5), px - 12, pad.t + plotH + 18); // show MM-DD
    });

    // Series
    for (const s of series) {
      ctx.strokeStyle = s.stroke || "#111";
      ctx.lineWidth = 2;
      ctx.beginPath();
      s.values.forEach((v, i) => {
        const px = pad.l + (i / Math.max(1, labels.length - 1)) * plotW;
        const py = pad.t + plotH - (v.y / yMax) * plotH;
        if (i === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      ctx.stroke();
    }
  }

  function setKpis({ topHeight, totalRuns, passRate, activeDays }) {
    const kpis = document.querySelectorAll("#kpis .card");
    const cards = [
      { label: "Top height", value: topHeight ?? "—" },
      { label: "Total runs (sample)", value: totalRuns ?? "—" },
      { label: "Pass rate (sample)", value: passRate ?? "—" },
      { label: "Active days (30d)", value: activeDays ?? "—" },
    ];
    cards.forEach((c, i) => {
      kpis[i].innerHTML = `
        <div class="kpiLabel">${c.label}</div>
        <div class="kpiValue">${c.value}</div>
      `;
    });
  }

  async function main() {
    // 1) Network/MDW status
    // MDW has a status endpoint; if your deployment differs, fall back to node status.
    // (You can swap this out if you prefer /v3/status from the node API.)
    let topHeight = null;
    try {
      const st = await fetchJson(`${MDW}/status`);
      topHeight = st.top_block_height ?? st.topHeight ?? null;
    } catch (_e) {}

    // 2) Pull recent logs for your runs contract
    // Endpoint documented in MDW swagger as contracts/logs with contract_id, limit, direction. :contentReference[oaicite:10]{index=10}
    const logsResp = await fetchJson(
      `${MDW}/contracts/logs?contract_id=${encodeURIComponent(CONTRACT_ID_RUNS)}&direction=backward&limit=${LOG_LIMIT}`
    );

    const rows = Array.isArray(logsResp.data) ? logsResp.data : (logsResp.data ?? logsResp); // tolerate shape differences
    const now = Date.now();
    const since30 = now - 30 * 24 * 3600 * 1000;

    // Aggregate per day
    const perDay = new Map(); // day -> {runs, pass, fail}
    let totalRuns = 0, pass = 0, fail = 0;

    // Your best UX is to standardize an emitted event like:
    // { event: "run_result", result: "success"|"failed", feature_hash, exec_ms, cost_damage, ... }
    // So we try to read result from common keys.
    for (const r of rows) {
      const ts = pickTimestampMs(r);
      if (ts < since30) continue;

      const day = isoDay(ts);
      const cur = perDay.get(day) || { runs: 0, pass: 0, fail: 0 };
      cur.runs++;

      // Try likely fields; adjust to your emitted schema.
      const result =
        (r.result ?? r.result_status ?? r.event_result ?? r.name ?? "").toString().toLowerCase();

      if (result.includes("success") || result.includes("pass")) { cur.pass++; pass++; }
      else if (result.includes("fail")) { cur.fail++; fail++; }

      totalRuns++;
      perDay.set(day, cur);
    }

    // Build a complete day axis (last 30 days)
    const days = [];
    for (let i = 29; i >= 0; i--) {
      const d = new Date(Date.now() - i * 24 * 3600 * 1000);
      days.push(`${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,"0")}-${String(d.getUTCDate()).padStart(2,"0")}`);
    }

    const seriesRuns = days.map(d => ({ xLabel: d, y: perDay.get(d)?.runs ?? 0 }));
    const seriesPass = days.map(d => ({ xLabel: d, y: perDay.get(d)?.pass ?? 0 }));
    const seriesFail = days.map(d => ({ xLabel: d, y: perDay.get(d)?.fail ?? 0 }));

    const activeDays = days.filter(d => (perDay.get(d)?.runs ?? 0) > 0).length;
    const passRate = totalRuns > 0 ? `${Math.round((pass / totalRuns) * 100)}%` : "—";

    setKpis({ topHeight, totalRuns, passRate, activeDays });

    // Recent list (top 8 rows)
    const recentEl = document.getElementById("recent");
    recentEl.innerHTML = rows.slice(0, 8).map(r => {
      const ts = new Date(pickTimestampMs(r)).toISOString().replace("T"," ").replace(".000Z","Z");
      const short = JSON.stringify(r).slice(0, 140);
      return `<div style="margin-bottom:10px;">
        <div style="color:#666; font-size:12px;">${ts}</div>
        <div style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size:12px;">${short}${short.length>=140?"…":""}</div>
      </div>`;
    }).join("");

    // Chart
    const canvas = document.getElementById("runsChart");
    drawLineChart(canvas, [
      { name: "runs", values: seriesRuns, stroke: "#111" },
      { name: "pass", values: seriesPass, stroke: "#2a7" },
      { name: "fail", values: seriesFail, stroke: "#c44" },
    ]);

    document.getElementById("legend").textContent = "lines: runs (black), pass (green), fail (red)";
    document.getElementById("lastUpdated").textContent = `updated ${new Date().toISOString().slice(0,19).replace("T"," ")}Z`;
  }

  // Run
  main().catch(err => {
    console.error(err);
    const kpis = document.getElementById("kpis");
    kpis.innerHTML = `<div class="card" style="grid-column:1/-1; border-color:#f4c;">
      <strong>Analytics fetch failed</strong><div style="color:#666; margin-top:6px;">${err.message}</div>
    </div>`;
  });
