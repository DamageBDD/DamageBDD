/*
  activity.js — standalone activity page script.

  - Reads account activities from AE Middleware v3:
      GET https://mainnet.aeternity.io/mdw/v3/accounts/<id>/activities
  - Fetches tx details:
      GET https://mainnet.aeternity.io/mdw/v3/transactions/<hash>
  - Filters contract calls with function == "spend"
  - Extracts {featureCid, reportCid, amount, timestamp, txhash}
  - Fetches first line of:
      /features/<featureCid>
  - Fetches report JSON:
      /reports/<reportCid>
*/

(() => {
  "use strict";

  const ready = (fn) => {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  };

  ready(() => {
    const $ = (sel) => document.querySelector(sel);

    // Lets this script be included globally without crashing other pages.
    const hasActivityPage =
      $("#activity-page") || $("#activity-account") || $("#run-reports-list");

    if (!hasActivityPage) return;

    // ---- Config
    const MDW_BASE = "https://mainnet.aeternity.io/mdw";
    const FEATURE_BASE = "/features/";
    const REPORT_BASE = "/reports/";
    const AESCAN_TX = (h) =>
      "https://aescan.io/transactions/" + encodeURIComponent(h);

    const PAGE_SIZE = 20;
    let page = 0;
    let currentRows = [];
    let loadSeq = 0;

    // ---- DOM
    const dom = {
      elAccount: $("#activity-account"),
      elRefresh: $("#activity-refresh"),
      elPrev: $("#run-reports-prev"),
      elNext: $("#run-reports-next"),
      elInfo: $("#run-reports-info"),
      elStatus: $("#run-reports-status"),
      elList: $("#run-reports-list")
    };

    const missing = Object.entries(dom)
      .filter(([, el]) => !el)
      .map(([name]) => name);

    if (missing.length) {
      console.warn("[activity] Missing required element(s): " + missing.join(", "));
      return;
    }

    const {
      elAccount,
      elRefresh,
      elPrev,
      elNext,
      elInfo,
      elStatus,
      elList
    } = dom;

    const setStatus = (msg, isError = false) => {
      elStatus.textContent = msg;
      elStatus.className = isError ? "error" : "meta";
    };

    const escapeHtml = (s) =>
      String(s ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");

    const isValidAeId = (s) => {
      s = String(s || "").trim();
      if (!(s.startsWith("ak_") || s.startsWith("ct_"))) return false;
      return s.length >= 12;
    };

    const fmtTs = (ts) => {
      const n = Number(ts);
      if (!Number.isFinite(n) || n <= 0) return "unknown time";
      const ms = n > 1e12 ? n : n * 1000;
      return new Date(ms).toLocaleString();
    };

    const firstLine = (text) => {
      const t = String(text || "");
      const i = t.indexOf("\n");
      const line = (i >= 0 ? t.slice(0, i) : t).trim();
      return line || "(untitled feature)";
    };

    const firstPresent = (...values) =>
      values.find((v) => v !== undefined && v !== null && String(v) !== "");

    const unwrapArg = (v) => {
      if (v && typeof v === "object") {
        if (Object.prototype.hasOwnProperty.call(v, "value")) {
          return unwrapArg(v.value);
        }
        if (Object.prototype.hasOwnProperty.call(v, "decoded")) {
          return unwrapArg(v.decoded);
        }
        if (Object.prototype.hasOwnProperty.call(v, "data")) {
          return unwrapArg(v.data);
        }
      }
      return v;
    };

    const argValue = (args, ...names) => {
      if (!args) return undefined;

      if (Array.isArray(args)) {
        for (const name of names) {
          const found = args.find(
            (a) =>
              a &&
              typeof a === "object" &&
              (a.name === name || a.key === name || a.id === name)
          );

          if (found) {
            return unwrapArg(
              found.value ?? found.decoded ?? found.data ?? found.arg
            );
          }
        }
        return undefined;
      }

      if (typeof args === "object") {
        for (const name of names) {
          if (Object.prototype.hasOwnProperty.call(args, name)) {
            return unwrapArg(args[name]);
          }
        }
      }

      return undefined;
    };

    async function fetchJson(url) {
      const r = await fetch(url, {
        headers: { accept: "application/json" }
      });

      if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
      return await r.json();
    }

    async function fetchText(url) {
      const r = await fetch(url, {
        headers: { accept: "text/plain" }
      });

      if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
      return await r.text();
    }

    function clampPage() {
      const maxPage = Math.max(0, Math.ceil(currentRows.length / PAGE_SIZE) - 1);
      page = Math.min(Math.max(page, 0), maxPage);
    }

    function setPager() {
      clampPage();

      const total = currentRows.length;
      const start = page * PAGE_SIZE;
      const end = Math.min(total, start + PAGE_SIZE);

      elInfo.textContent = total ? `${start + 1}-${end} of ${total}` : "";
      elPrev.disabled = page <= 0;
      elNext.disabled = end >= total;
    }

    function renderRows() {
      clampPage();
      elList.innerHTML = "";

      const total = currentRows.length;
      const start = page * PAGE_SIZE;
      const end = Math.min(total, start + PAGE_SIZE);
      const slice = currentRows.slice(start, end);

      if (!slice.length) {
        elList.innerHTML = `<li class="item"><div class="meta">No runs found.</div></li>`;
        setPager();
        return;
      }

      for (const row of slice) {
        const featureUrl = FEATURE_BASE + encodeURIComponent(row.featureCid);
        const reportUrl = REPORT_BASE + encodeURIComponent(row.reportCid);

        const txLink = row.txhash
          ? `<a class="tag" href="${AESCAN_TX(row.txhash)}" target="_blank" rel="noopener noreferrer">Tx</a>`
          : `<span class="tag meta">Tx unavailable</span>`;

        const li = document.createElement("li");
        li.className = "item";

        li.innerHTML = `
          <div class="item-head">
            <div class="item-title">${escapeHtml(row.featureTitle || "(loading title…)")}</div>
            <div class="item-meta">${escapeHtml(fmtTs(row.timestamp))}</div>
          </div>

          <div class="tags">
            <a class="tag" href="${featureUrl}">Feature</a>
            <a class="tag" href="${reportUrl}">Report</a>
            ${txLink}
            <span class="tag"><span class="verified">DAMAGE</span>&nbsp;${escapeHtml(String(row.amount ?? ""))}</span>
            ${
              row.reportCount != null
                ? `<span class="tag">Items&nbsp;${escapeHtml(String(row.reportCount))}</span>`
                : `<span class="tag meta">Items&nbsp;…</span>`
            }
          </div>

          <div class="kv">
            <div class="k">Account</div><div class="v mono">${escapeHtml(row.account)}</div>
            <div class="k">Feature CID</div><div class="v mono">${escapeHtml(row.featureCid)}</div>
            <div class="k">Report CID</div><div class="v mono">${escapeHtml(row.reportCid)}</div>
            <div class="k">Tx Hash</div><div class="v mono">${escapeHtml(row.txhash || "")}</div>
          </div>
        `;

        elList.appendChild(li);
      }

      setPager();
    }

    async function hydrate(rows, seq) {
      const limit = Math.min(10, rows.length);
      let idx = 0;

      async function worker() {
        while (idx < rows.length) {
          if (seq !== loadSeq) return;

          const i = idx++;
          const r = rows[i];

          try {
            const t = await fetchText(
              FEATURE_BASE + encodeURIComponent(r.featureCid)
            );
            r.featureTitle = firstLine(t);
          } catch {
            r.featureTitle = "(feature unavailable)";
          }

          try {
            const rep = await fetchJson(
              REPORT_BASE + encodeURIComponent(r.reportCid)
            );

            if (Array.isArray(rep)) {
              r.reportCount = rep.length;
            } else if (rep && typeof rep === "object") {
              if (Array.isArray(rep.items)) {
                r.reportCount = rep.items.length;
              } else {
                r.reportCount = Object.keys(rep).length;
              }
            } else {
              r.reportCount = null;
            }
          } catch {
            r.reportCount = null;
          }

          if (seq === loadSeq) renderRows();
        }
      }

      await Promise.all(Array.from({ length: limit }, worker));
    }

    function syncFromUrl() {
      try {
        const u = new URL(location.href);
        const a = u.searchParams.get("account");
        if (a) elAccount.value = a;
      } catch {
        // ignore
      }
    }

    function setUrlAccount(a) {
      try {
        const u = new URL(location.href);

        if (a) u.searchParams.set("account", a);
        else u.searchParams.delete("account");

        history.replaceState(null, "", u.toString());
      } catch {
        // ignore
      }
    }

    function extractRun(account, source) {
      const tx = source.tx || source;

      const txhash = firstPresent(
        source.hash,
        tx?.hash,
        tx?.tx_hash,
        tx?.tx?.hash,
        tx?.tx?.tx_hash
      );

      const fn = firstPresent(
        tx?.contract_call?.function,
        tx?.tx?.contract_call?.function,
        tx?.function,
        tx?.tx?.function
      );

      if (fn !== "spend") return null;

      const argSources = [
        tx?.contract_call?.arguments,
        tx?.tx?.contract_call?.arguments,
        tx?.arguments,
        tx?.tx?.arguments
      ].filter(Boolean);

      const featureCid = firstPresent(
        ...argSources.map((args) =>
          argValue(args, "featureCid", "feature_cid", "feature")
        ),
        tx?.featureCid,
        tx?.feature_cid,
        tx?.tx?.featureCid,
        tx?.tx?.feature_cid
      );

      const reportCid = firstPresent(
        ...argSources.map((args) =>
          argValue(args, "reportCid", "report_cid", "report")
        ),
        tx?.reportCid,
        tx?.report_cid,
        tx?.tx?.reportCid,
        tx?.tx?.report_cid
      );

      if (!featureCid || !reportCid) return null;

      const amount = firstPresent(
        ...argSources.map((args) => argValue(args, "amount", "tokens", "value")),
        tx?.contract_call?.amount,
        tx?.tx?.contract_call?.amount,
        tx?.amount,
        tx?.tx?.amount,
        ""
      );

      const timestamp = firstPresent(
        tx?.block_time,
        tx?.time,
        tx?.tx?.block_time,
        tx?.tx?.time,
        source.block_time,
        source.time,
        ""
      );

      return {
        account,
        featureCid: String(featureCid),
        reportCid: String(reportCid),
        amount,
        timestamp,
        txhash: String(txhash || ""),
        featureTitle: null,
        reportCount: null
      };
    }

    async function loadActivity(account) {
      const seq = ++loadSeq;

      setStatus("Loading activity…");
      elRefresh.disabled = true;

      try {
        const acts = await fetchJson(
          `${MDW_BASE}/v3/accounts/${encodeURIComponent(account)}/activities`
        );

        if (seq !== loadSeq) return;

        const txHashes =
          acts && Array.isArray(acts.data)
            ? acts.data
                .map((x) => x?.tx_hash || x?.hash || x?.tx?.hash || x?.tx?.tx_hash)
                .filter(Boolean)
            : [];

        const txs = [];
        const concurrency = Math.min(12, txHashes.length);
        let p = 0;

        async function w() {
          while (p < txHashes.length) {
            if (seq !== loadSeq) return;

            const i = p++;
            const h = txHashes[i];

            try {
              const tx = await fetchJson(
                `${MDW_BASE}/v3/transactions/${encodeURIComponent(h)}`
              );
              txs.push({ hash: h, tx });
            } catch {
              // Ignore individual transaction failures.
            }
          }
        }

        await Promise.all(Array.from({ length: concurrency }, w));

        if (seq !== loadSeq) return;

        const runs = txs
          .map((source) => extractRun(account, source))
          .filter(Boolean)
          .sort((a, b) => Number(b.timestamp || 0) - Number(a.timestamp || 0));

        currentRows = runs;
        page = 0;
        renderRows();

        if (!runs.length) {
          setStatus("No paid runs found for this account.");
        } else {
          setStatus(`Found ${runs.length} run(s). Hydrating titles + report counts…`);
          await hydrate(runs, seq);

          if (seq === loadSeq) {
            setStatus(`Loaded ${runs.length} run(s).`);
          }
        }
      } catch (e) {
        if (seq !== loadSeq) return;

        setStatus("Failed to load activity: " + (e?.message || String(e)), true);
        currentRows = [];
        page = 0;
        renderRows();
      } finally {
        if (seq === loadSeq) elRefresh.disabled = false;
      }
    }

    function onRun() {
      const v = String(elAccount.value || "").trim();
      const ok = isValidAeId(v);

      elAccount.classList.toggle("invalid", !ok);

      if (!ok) {
        setStatus("Enter a valid ak_… or ct_… id.", true);
        return;
      }

      setUrlAccount(v);
      loadActivity(v);
    }

    // Events — safe because all elements were checked above.
    elRefresh.addEventListener("click", onRun);

    elAccount.addEventListener("change", onRun);

    elAccount.addEventListener("keydown", (e) => {
      if (e.key === "Enter") onRun();
    });

    elPrev.addEventListener("click", () => {
      if (page > 0) {
        page--;
        renderRows();
      }
    });

    elNext.addEventListener("click", () => {
      const lastPage = Math.max(0, Math.ceil(currentRows.length / PAGE_SIZE) - 1);

      if (page < lastPage) {
        page++;
        renderRows();
      }
    });

    // Init
    syncFromUrl();
    setPager();

    if (String(elAccount.value || "").trim()) {
      onRun();
    }
  });
})();
