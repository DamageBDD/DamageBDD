// featurePicker.js
// DamageBDD Feature Picker — vanilla JS, no deps.
// Usage:
//   import { initDamageBDDPicker } from './featurePicker.js';
//   initDamageBDDPicker({
//     mount: '#picker',
//     editor: '#editor',
//     hashes: ['bafy...','Qm...'], // or [{ cid:'Qm...', label:'Home page search' }]
//     gateway: 'https://cloudflare-ipfs.com/ipfs', // any public or private gateway
//   });

export async function initDamageBDDPicker(opts) {
  const {
	  opener,
    mount,
    editor,
    hashes,
    gateway = 'https://cloudflare-ipfs.com/ipfs',
    title = 'DamageBDD Feature Picker',
  } = opts || {};

  if (!opener) throw new Error('initDamageBDDPicker: "opener" selector is required');
  if (!mount) throw new Error('initDamageBDDPicker: "mount" selector is required');
  if (!editor) throw new Error('initDamageBDDPicker: "editor" selector is required');
  if (!hashes || !hashes.length) throw new Error('initDamageBDDPicker: "hashes" must be a non-empty array');

  const $opener = typeof mount === 'string' ? document.querySelector(opener) : opener;
  const $root = typeof mount === 'string' ? document.querySelector(mount) : mount;
  const $editor = typeof editor === 'string' ? document.querySelector(editor) : editor;
  if (!$root) throw new Error(`initDamageBDDPicker: mount "${mount}" not found`);
  if (!$editor) throw new Error(`initDamageBDDPicker: editor "${editor}" not found`);
    $opener.onclick = (event) => {
		MicroModal.show('feature-picker-modal');
		event.preventDefault(); // Prevent default form submission

    };

  injectStylesOnce();

  // Normalize into [{cid,label}]
  const items = hashes.map(h => (typeof h === 'string' ? { cid: h, label: h } : h));

  // Build shell
  $root.classList.add('dbdd-picker');
  $root.innerHTML = `
    <div class="dbdd-header">
      <div class="dbdd-title">${escapeHtml(title)}</div>
      <div class="dbdd-actions">
        <input class="dbdd-search" type="search" placeholder="Search features…" />
        <button class="dbdd-refresh" aria-label="Refresh">↻</button>
      </div>
    </div>
    <div class="dbdd-body">
      <div class="dbdd-list" role="list"></div>
      <div class="dbdd-detail" aria-live="polite" aria-atomic="true">
        <div class="dbdd-detail-empty">Select a feature to preview</div>
      </div>
    </div>
    <div class="dbdd-toast" hidden></div>
  `;

  const $list = $root.querySelector('.dbdd-list');
  const $detail = $root.querySelector('.dbdd-detail');
  const $search = $root.querySelector('.dbdd-search');
  const $refresh = $root.querySelector('.dbdd-refresh');
  const $toast = $root.querySelector('.dbdd-toast');

  // Data cache
  const cache = new Map(); // cid -> { text, meta, error }

  async function loadAll() {
    $list.innerHTML = '';
    const cards = [];

    for (const { cid, label } of items) {
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'dbdd-card';
      card.setAttribute('role', 'listitem');
      card.dataset.cid = cid;
      card.innerHTML = `
        <div class="dbdd-card-top">
          <span class="dbdd-card-cid" title="${escapeHtml(cid)}">${escapeHtml(shortCid(cid))}</span>
          <span class="dbdd-chip">loading…</span>
        </div>
        <div class="dbdd-card-title ellipsis">Fetching…</div>
        <div class="dbdd-card-desc ellipsis"></div>
      `;
      $list.appendChild(card);
      cards.push(card);

      // fetch (lazy but kicked immediately)
      fetchFeature(cid, gateway)
        .then(({ text, meta }) => {
          cache.set(cid, { text, meta });
          card.querySelector('.dbdd-chip').textContent = 'ready';
          card.querySelector('.dbdd-card-title').textContent = meta.title || label || cid;
          card.querySelector('.dbdd-card-desc').textContent = meta.description || '(no description)';
        })
        .catch(err => {
          cache.set(cid, { error: err });
          card.querySelector('.dbdd-chip').textContent = 'error';
          card.querySelector('.dbdd-card-title').textContent = label || cid;
          card.querySelector('.dbdd-card-desc').textContent = 'Failed to fetch or parse';
          card.classList.add('dbdd-card-error');
        });
    }

    // click handling
    $list.addEventListener('click', e => {
      const $btn = e.target.closest('.dbdd-card');
      if (!$btn) return;
      const cid = $btn.dataset.cid;
      const rec = cache.get(cid);
      if (!rec) return;
      showDetail(cid, rec);
      // mark selected
      $list.querySelectorAll('.dbdd-card.selected').forEach(el => el.classList.remove('selected'));
      $btn.classList.add('selected');
    });
  }

  function showDetail(cid, rec) {
    if (rec.error) {
      $detail.innerHTML = `
        <div class="dbdd-detail-error">
          <div class="dbdd-detail-head">
            <span class="dbdd-detail-cid">${escapeHtml(cid)}</span>
            <span class="dbdd-chip chip-error">error</span>
          </div>
          <p>Could not load this feature. Check gateway or CID.</p>
          <div class="dbdd-detail-actions">
            <a class="dbdd-link" target="_blank" rel="noopener" href="${gateway}/${cid}">Open on gateway</a>
          </div>
        </div>
      `;
      return;
    }

    const { text, meta } = rec;
    const preview = meta.headSnippet || text.slice(0, 1500);
    $detail.innerHTML = `
      <div class="dbdd-detail-head">
        <div class="dbdd-detail-left">
          <div class="dbdd-detail-title">${escapeHtml(meta.title || '(Untitled Feature)')}</div>
          <div class="dbdd-detail-sub">${escapeHtml(meta.description || '')}</div>
        </div>
        <div class="dbdd-detail-right">
          <span class="dbdd-detail-cid">${escapeHtml(shortCid(cid))}</span>
          <a class="dbdd-link" target="_blank" rel="noopener" href="${gateway}${cid}">View raw</a>
        </div>
      </div>
      <pre class="dbdd-code"><code>${escapeHtml(preview)}</code></pre>
      <div class="dbdd-detail-actions">
        <button class="dbdd-insert">Insert into editor</button>
        <button class="dbdd-copy">Copy to clipboard</button>
      </div>
    `;

    $detail.querySelector('.dbdd-insert').onclick = () => {
      insertIntoEditor($editor, text);
		MicroModal.close('feature-picker-modal');
      toast(`Inserted feature from ${shortCid(cid)} into editor`, $toast);
    };
    $detail.querySelector('.dbdd-copy').onclick = async () => {
      try {
        await navigator.clipboard.writeText(text);
        toast('Copied feature to clipboard', $toast);
      } catch {
        toast('Clipboard copy failed', $toast);
      }
    };
  }

  $search.addEventListener('input', () => {
    const q = $search.value.trim().toLowerCase();
    for (const $card of $list.querySelectorAll('.dbdd-card')) {
      const cid = $card.dataset.cid;
      const rec = cache.get(cid);
      const t = ($card.querySelector('.dbdd-card-title')?.textContent || '') + ' ' +
                ($card.querySelector('.dbdd-card-desc')?.textContent || '') + ' ' + cid;
      $card.style.display = t.toLowerCase().includes(q) ? '' : 'none';
    }
  });

  $refresh.addEventListener('click', () => {
    cache.clear();
    loadAll();
  });

  await loadAll();
}

// ----------------------------- helpers -----------------------------

async function fetchFeature(cid, gateway) {
  const url = `${gateway.replace(/\/+$/, '')}/${cid}`;
  const res = await fetch(url, { mode: 'cors' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  const meta = parseGherkinHead(text);
  return { text, meta };
}

// Extract "summary from the head": the Feature line + its contiguous description lines
function parseGherkinHead(text) {
  // Normalize line endings
  const lines = text.replace(/\r\n?/g, '\n').split('\n');

  // find "Feature:" (case-insensitive, allow leading whitespace and comments before)
  let featureIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^Feature\s*:/.test(s)) { featureIdx = i; break; }
  }

  let title = '';
  let description = '';
  if (featureIdx >= 0) {
    title = lines[featureIdx].replace(/^\s*Feature\s*:\s*/i, '').trim();

    // Collect description lines until blank line or a new Gherkin section (Scenario/Rule/Background)
    const desc = [];
    for (let i = featureIdx + 1; i < lines.length; i++) {
      const raw = lines[i];
      const t = raw.trim();
      if (t === '') break;
      if (/^(Scenario|Rule|Background)\b/i.test(t)) break;
      // Stop if we encounter tags line for next block
      if (/^@/.test(t)) break;
      // Keep comment lines (# …) and plain prose
      desc.push(raw.replace(/^\s*#\s?/, '').trimEnd());
    }
    description = desc.join('\n').trim();
  }

  // Build a compact head snippet (first ~40 lines or until first scenario)
  const headLines = [];
  for (let i = 0; i < Math.min(lines.length, 200); i++) {
    const t = lines[i].trim();
    if (/^(Scenario|Rule|Background)\b/i.test(t) && headLines.length > 0) break;
    headLines.push(lines[i]);
  }
  const headSnippet = headLines.slice(0, 40).join('\n');

  return { title, description, headSnippet };
}

function insertIntoEditor($editor, content) {
  const isInputish = $editor instanceof HTMLTextAreaElement || $editor instanceof HTMLInputElement;
  const isContentEditable = $editor.hasAttribute('contenteditable');

  if (isInputish) {
    $editor.value = content;
    $editor.dispatchEvent(new Event('input', { bubbles: true }));
    $editor.focus();
  } else if (isContentEditable) {
    // Preserve newlines by converting to <br>
    $editor.innerText = ''; // clear
    // Use textContent to avoid injecting HTML; preserve as plain text
    $editor.textContent = content;
    // Move caret to end
    placeCaretAtEnd($editor);
  } else {
    throw new Error('Editor must be a <textarea>, <input>, or contenteditable element');
  }
}

function placeCaretAtEnd(el) {
  el.focus();
  if (typeof window.getSelection != "undefined" && document.createRange) {
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
}

function toast(msg, $toast) {
  $toast.textContent = msg;
  $toast.hidden = false;
  $toast.classList.add('show');
  window.clearTimeout($toast._t);
  $toast._t = window.setTimeout(() => {
    $toast.classList.remove('show');
    $toast.hidden = true;
  }, 2400);
}

function shortCid(cid) {
  return cid.length > 16 ? `${cid.slice(0, 8)}…${cid.slice(-6)}` : cid;
}

function escapeHtml(s) {
  return String(s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

let __DBDD_STYLES_INJECTED__ = false;
function injectStylesOnce() {
  if (__DBDD_STYLES_INJECTED__) return;
  __DBDD_STYLES_INJECTED__ = true;
  const css = `
  .dbdd-picker{--bg:#0c0f14;--muted:#a8b3cf;--card:#121826;--card2:#0f1522;--border:#263043;--brand:#79ffe1;--brand-2:#a8ff63;--err:#ff6b6b;color:#e6eefc;background:var(--bg);border:1px solid var(--border);border-radius:16px;padding:12px;display:flex;flex-direction:column;gap:12px;font:14px/1.35 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Inter,"Helvetica Neue",Arial;}
  .dbdd-header{display:flex;justify-content:space-between;align-items:center;gap:12px}
  .dbdd-title{font-weight:700;font-size:16px}
  .dbdd-actions{display:flex;gap:8px;align-items:center}
  .dbdd-search{background:var(--card);border:1px solid var(--border);color:inherit;border-radius:10px;padding:8px 10px;min-width:220px;outline:none}
  .dbdd-refresh{background:var(--card);border:1px solid var(--border);color:var(--muted);border-radius:10px;padding:8px 10px;cursor:pointer}
  .dbdd-body{display:grid;grid-template-columns: 1fr minmax(280px, 42%); gap:12px;}
  .dbdd-list{display:grid;grid-template-columns: repeat(auto-fill, minmax(220px,1fr)); gap:10px; align-content:start; max-height:420px; padding-right:2px}
  .dbdd-card{display:flex;flex-direction:column;gap:6px;background:linear-gradient(180deg,var(--card),var(--card2));border:1px solid var(--border);border-radius:12px;padding:10px;text-align:left;color:inherit;cursor:pointer;transition:transform .06s ease,border-color .15s ease}
  .dbdd-card:hover{transform:translateY(-1px);border-color:#3b4a66}
  .dbdd-card.selected{outline:2px solid var(--brand);outline-offset:2px}
  .dbdd-card-error{border-color:#5a3131}
  .dbdd-card-top{display:flex;justify-content:space-between;align-items:center}
  .dbdd-card-cid{font-family:ui-monospace,Consolas,Menlo,monospace;font-size:12px;color:var(--muted)}
  .dbdd-chip{font-size:11px;border:1px solid var(--border);border-radius:999px;padding:2px 6px;color:var(--muted);background:#0b1524}
  .chip-error{border-color:#6e3a3a;color:#ff9c9c;background:#241014}
  .dbdd-card-title{font-weight:600}
  .dbdd-card-desc{font-size:12px;color:var(--muted);min-height:2.2em}
  .ellipsis{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
  .dbdd-detail{background:linear-gradient(180deg,#0e1422,#0c111d);border:1px solid var(--border);border-radius:12px;padding:12px;min-height:220px;display:flex;flex-direction:column;gap:10px}
  .dbdd-detail-empty{color:var(--muted);margin:auto}
  .dbdd-detail-head{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}
  .dbdd-detail-title{font-size:15px;font-weight:700}
  .dbdd-detail-sub{white-space:pre-wrap;color:var(--muted)}
  .dbdd-detail-left{width: 50%; white-space: normal; word-wrap: break-word; overflow-wrap: break-word;}
  .dbdd-detail-right{display:flex;gap:10px;align-items:center}
  .dbdd-detail-cid{font-family:ui-monospace,Consolas,Menlo,monospace;font-size:12px;color:var(--muted)}
  .dbdd-link{font-size:12px;color:var(--brand);text-decoration:none;border-bottom:1px dotted var(--brand)}
  .dbdd-code{background:#0a0f1a;border:1px solid var(--border);border-radius:10px;padding:10px;max-height:260px;overflow:auto}
  .dbdd-detail-actions{display:flex;gap:8px}
  .dbdd-detail-actions button{background:var(--card);border:1px solid var(--border);color:inherit;border-radius:10px;padding:8px 10px;cursor:pointer}
  .dbdd-toast{position:relative;align-self:flex-start;background:#0b1822;border:1px solid #1e2b3f;padding:8px 10px;border-radius:10px;opacity:0;transform:translateY(-6px);transition:all .2s ease;color:#d8f3ff}
  .dbdd-toast.show{opacity:1;transform:translateY(0)}
  `;
  const el = document.createElement('style');
  el.setAttribute('data-dbdd-picker', 'true');
  el.textContent = css;
  document.head.appendChild(el);
}
