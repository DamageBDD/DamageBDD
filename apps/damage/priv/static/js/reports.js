/* DamageBDD Run history — public, read-only, on-chain evidence.
 * Sources: AEMDW token transactions and node/account activities;
 * optional recent NodeRegistry discovery; feature source, run.meta and report
 * files are served by this DamageBDD node via its existing IPFS-backed APIs.
 * Nothing here reads an auth token, signing key or private run context.
 */
import {
  aeAddress, isCid, txHashOf, normalizeSpend, plausibleRunTransaction, parseFeature, normalizeRunMeta,
  parseLegacyStatus, parseTagFilter, rangeBounds, matchesRun, middlewareUrl,
  registryRegistration, DEFAULT_REGISTRY_CONTRACT,
  DEFAULT_TOKEN_CONTRACT, DEFAULT_MDW
} from './run-history-model.js';
import {TokenManager} from './wallet-switcher.js';

const $ = id => document.getElementById(id);
const text = v => String(v ?? '').trim();
const compact = (s, n = 9) => text(s).length > n * 2 + 3 ?
  `${text(s).slice(0, n)}…${text(s).slice(-n)}` : text(s);
const node = (tag, className = '', contents = '') => {
  const el = document.createElement(tag);
  if (className) el.className = className;
  el.textContent = contents;
  return el;
};
const formatTime = ms => ms ? new Date(ms).toLocaleString() : 'Date unknown';
const safeLink = (label, url) => {
  const a = node('a', 'activity-link', label);
  a.href = url; a.target = '_blank'; a.rel = 'noopener noreferrer';
  return a;
};
const tokenAmount = raw => {
  const digits = text(raw);
  if (!/^\d+$/.test(digits)) return '—';
  const padded = digits.padStart(9, '0');
  const integral = padded.slice(0, -8).replace(/^0+(?=\d)/, '');
  const decimal = padded.slice(-8).replace(/0+$/, '');
  return `${integral}${decimal ? '.' + decimal : ''} DAMAGE`;
};
const SOURCE_PAGE_LIMIT = 100;
const REGISTRY_SCAN_PAGES = 3; // A bounded recent-history index, not contract state.
const REGISTRY_DETAIL_LIMIT = 24;
const TX_PARALLEL = 8;
const EVIDENCE_PARALLEL = 6;
const MAX_BYTES = 128 * 1024;
const AUTO_SCAN_PAGES = 3; // Continue beyond empty first pages; Load more for older history.
const DEFAULT_SCOPE = 'node';

function localPreferences() {
  return {scope: DEFAULT_SCOPE, range: 'all'};
}
function config() {
  return {
    mdw: window.DamageActivity?.mdwBase || DEFAULT_MDW,
    token: window.DamageActivity?.damageTokenContract || DEFAULT_TOKEN_CONTRACT,
    registry: aeAddress($('run-history-workspace')?.dataset.registry, ['ct_']) ||
      aeAddress(window.DamageActivity?.nodeRegistryContract, ['ct_']) || DEFAULT_REGISTRY_CONTRACT
  };
}
function reportUrl(cid) { return `/reports/${encodeURIComponent(cid)}/`; }
function featureUrl(cid) { return `/features/${encodeURIComponent(cid)}/`; }
function publicTxUrl(hash) { return `https://aescan.io/transactions/${encodeURIComponent(hash)}`; }
function accountUrl(id) { return `https://aescan.io/accounts/${encodeURIComponent(id)}`; }

async function fetchPublic(url, {as = 'json', timeout = 11000, accept = null} = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const res = await fetch(url, {credentials: 'omit', signal: controller.signal,
      headers: {accept: accept || (as === 'json' ? 'application/json' : 'text/plain')} });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    if (as === 'json') return res.json();
    // Do not load unbounded remote report bodies into browser memory.
    if (!res.body?.getReader) return (await res.text()).slice(0, MAX_BYTES);
    const reader = res.body.getReader(), decoder = new TextDecoder();
    let count = 0, out = '';
    try {
      while (count < MAX_BYTES) {
        const {done, value} = await reader.read();
        if (done) break;
        const part = value.subarray(0, Math.max(0, MAX_BYTES - count));
        count += part.length;
        out += decoder.decode(part, {stream: true});
      }
    } finally { await reader.cancel().catch(() => {}); }
    return out + decoder.decode();
  } finally { clearTimeout(timer); }
}
const taskQueue = async (items, count, process) => {
  let idx = 0;
  await Promise.all(Array.from({length: Math.min(count, items.length)}, async () => {
    while (idx < items.length) {
      const i = idx++;
      await process(items[i], i);
    }
  }));
};

function loadFollowed(account) {
  try {
    const saved = JSON.parse(localStorage.getItem(`damagebdd.history.followed.v1:${account}`) || '[]');
    return Array.isArray(saved) ? [...new Set(saved.filter(id => aeAddress(id)))].slice(0, 32) : [];
  } catch { return []; }
}
function saveFollowed(state) {
  try { localStorage.setItem(`damagebdd.history.followed.v1:${state.owner}`, JSON.stringify(state.followed)); }
  catch { /* Storage may be blocked in private browsing. */ }
}

function createState(host) {
  const owner = aeAddress(host?.dataset.account, ['ak_']);
  const localNode = aeAddress(host?.dataset.node);
  const prefs = localPreferences();
  const state = {
    host, owner, localNode, targetNode: localNode, accountTarget: owner,
    scope: localNode ? prefs.scope : (owner ? 'account' : 'discover'),
    followed: loadFollowed(owner), registryNodes: new Map(), knownAccounts: new Set(owner ? [owner] : []),
    sources: [], rows: [], seen: new Set(), txCache: new Map(),
    metaCache: new Map(), featureCache: new Map(), statusCache: new Map(),
    version: 0, loading: false, ready: false, range: prefs.range, explicitScope: false,
    scannedTransactions: 0, undecodedCalls: 0,
    registryScan: null, registryScanPromise: null
  };
  if (localNode) state.registryNodes.set(localNode, {id: localNode, name: 'This node', registered: false});
  return state;
}

function status(s) { const el = $('activity-status'); if (el) el.textContent = s; }
function registryStatus(s) { const el = $('activity-registry-status'); if (el) el.textContent = s; }
function setScope(state, scope, {refresh = true} = {}) {
  if (!['node', 'account', 'followed', 'discover'].includes(scope)) return;
  state.scope = scope;
  $('activity-directory-heading').textContent = scope === 'discover' ?
    'Discover public nodes' : 'Browse public node activity';
  // Registry controls are supplementary to the run list. Open on demand.
  $('activity-directory').open = scope === 'discover';
  for (const b of document.querySelectorAll('[data-history-scope]')) {
    b.setAttribute('aria-pressed', String(b.dataset.historyScope === scope));
  }
  $('activity-account-field').hidden = scope !== 'account';
  $('activity-node-field').hidden = scope === 'account';
  $('activity-node-manual-field').hidden = scope === 'account';
  $('activity-account-filter-field').hidden = scope === 'account';
  if (scope === 'account') $('activity-account').value = state.accountTarget;
  if (scope === 'followed' && !state.followed.length) {
    registryStatus('No followed nodes yet. Select an observed or known public node, then choose Follow.');
  }
  fillNodeOptions(state);
  if (refresh) startSearch(state);
}

function addRegistryNodes(state, rows) {
  for (const n of rows || []) {
    const id = aeAddress(n.id);
    if (!id) continue;
    const previous = state.registryNodes.get(id) || {};
    state.registryNodes.set(id, {...previous, ...n, id});
  }
  fillNodeOptions(state);
}
function fillKnownAccounts(state) {
  const ctl = $('activity-account-known');
  if (!ctl) return;
  const current = state.accountTarget;
  ctl.replaceChildren();
  ctl.add(new Option('Choose an account from public runs…', ''));
  for (const id of [...state.knownAccounts].sort()) {
    ctl.add(new Option(`${id === state.owner ? 'My account · ' : ''}${compact(id)}`, id));
  }
  ctl.value = state.knownAccounts.has(current) ? current : '';
}
function fillNodeOptions(state) {
  const ctl = $('activity-node'); if (!ctl) return;
  const chosen = state.targetNode || '';
  ctl.replaceChildren();
  if (state.scope === 'followed') {
    ctl.add(new Option('All followed nodes', 'all'));
    for (const id of state.followed) {
      const item = state.registryNodes.get(id);
      ctl.add(new Option(`${item?.name && item.name !== id ? item.name + ' · ' : ''}${compact(id)}`, id));
    }
    ctl.value = state.followed.includes(chosen) ? chosen : 'all';
    return;
  }
  ctl.add(new Option('Choose node…', ''));
  const all = [...state.registryNodes.values()];
  for (const item of all) {
    const label = `${item.name && item.name !== item.id ? item.name : 'Node'} · ${compact(item.id)}`;
    ctl.add(new Option(label, item.id));
  }
  if (chosen && !all.some(n => n.id === chosen)) ctl.add(new Option(compact(chosen), chosen));
  ctl.value = chosen;
}
function follow(state, id) {
  if (!state.followed.includes(id)) state.followed.push(id);
  else state.followed = state.followed.filter(x => x !== id);
  saveFollowed(state);
  $('activity-follow-count').textContent = state.followed.length ? `(${state.followed.length})` : '';
  fillNodeOptions(state); renderRegistryNodes(state);
  if (state.scope === 'followed') startSearch(state);
}
function viewNode(state, id) {
  state.targetNode = id;
  state.explicitScope = true;
  $('activity-node-manual').value = id;
  setScope(state, 'node');
}
function renderRegistryNodes(state) {
  const ul = $('activity-node-results'); if (!ul) return;
  ul.replaceChildren();
  for (const n of [...state.registryNodes.values()]) {
    const li = node('li', 'history-node');
    const info = node('div', 'history-node-info');
    info.append(node('strong', '', n.name && n.name !== n.id ? n.name :
      n.observed ? 'Registration observed on chain' : n.id === state.localNode ? 'This node' : 'Public node'));
    info.append(node('code', '', compact(n.id, 12)));
    if (n.location || n.version || n.owner) info.append(node('small', '',
      [n.location, n.version, n.owner ? `Historical owner ${compact(n.owner)}` : ''].filter(Boolean).join(' · ')));
    li.append(info);
    const actions = node('div', 'history-node-actions');
    const open = node('button', 'workspace-button', 'View runs'); open.type = 'button';
    open.addEventListener('click', () => viewNode(state, n.id));
    const toggle = node('button', 'workspace-button', state.followed.includes(n.id) ? 'Following ✓' : '+ Follow');
    toggle.type = 'button'; toggle.setAttribute('aria-pressed', String(state.followed.includes(n.id)));
    toggle.title = 'Following a public node does not imply current NodeRegistry registration';
    toggle.addEventListener('click', () => follow(state, n.id));
    actions.append(open, toggle); li.append(actions); ul.append(li);
  }
}
// Node discovery reads historical registration transactions directly from
// AEMDW; it never depends on a /api/run-history/nodes application route.
// NodeRegistry v2 lacks an enumerable global state API, so these results are
// explicitly recent *observations*, not a current/complete registry snapshot.
async function scanRegistry(state) {
  if (state.registryScanPromise) return state.registryScanPromise;
  state.registryScanPromise = (async () => {
    const registry = config().registry;
    if (!aeAddress(registry, ['ct_'])) throw new Error('NodeRegistry contract not configured');
    const results = new Map();
    let scanned = 0, pages = 0, next =
      `/v3/transactions?contract=${encodeURIComponent(registry)}&type=contract_call&type=paying_for&direction=backward&limit=100`;
    while (next && pages < REGISTRY_SCAN_PAGES) {
      const page = await fetchActivity(middlewareUrl(config().mdw, next));
      const calls = Array.isArray(page?.data) ? page.data : [];
      pages += 1;
      scanned += calls.length;
      // External register_node transactions can carry the entrypoint under
      // tx or payload.tx rather than on the top-level middleware row.
      const candidates = calls.filter(row =>
        String(row?.function || row?.tx?.function || row?.payload?.tx?.function ||
          row?.entrypoint || row?.function_name || '').split('.').pop() === 'register_node');
      await taskQueue(candidates.slice(0, REGISTRY_DETAIL_LIMIT), TX_PARALLEL, async row => {
        let parsed = registryRegistration(row, {registryContract: registry, trustedRegistryScope: true});
        if (!parsed) {
          const hash = txHashOf(row);
          if (hash) {
            const full = await getTx(state, hash);
            parsed = registryRegistration(full, {registryContract: registry,
              trustedRegistryScope: true});
          }
        }
        if (parsed) results.set(parsed.id, parsed);
      });
      const following = page?.next ? middlewareUrl(config().mdw, page.next) : null;
      next = following && following !== middlewareUrl(config().mdw, next) && calls.length ? following : null;
    }
    const data = {nodes: [...results.values()], scanned, pages, complete: !next};
    state.registryScan = data;
    addRegistryNodes(state, data.nodes);
    renderRegistryNodes(state);
    return data;
  })();
  try { return await state.registryScanPromise; }
  catch (error) { state.registryScanPromise = null; throw error; }
}
async function ownerLookup(state, owner, {quiet = false} = {}) {
  const account = aeAddress(owner, ['ak_']); if (!account) return [];
  if (!quiet) registryStatus('Looking for historical registration calls on public æternity middleware…');
  try {
    const data = await scanRegistry(state);
    const rows = data.nodes.filter(n => n.owner === account);
    if (!quiet) registryStatus(`${rows.length} node registration(s) observed for ${compact(account)} ` +
      `in ${data.scanned} recently scanned registry transactions. Older records may not be included.`);
    return rows;
  } catch (err) {
    if (!quiet) registryStatus(`Public NodeRegistry history unavailable: ${err.message}`);
    return [];
  }
}
async function doRegistryLookup(state) {
  const id = aeAddress($('activity-registry-query').value);
  if (!id) { registryStatus('Enter an ak_ account or ak_/ct_ node address.'); return; }
  $('activity-registry-lookup').disabled = true;
  try {
    const data = await scanRegistry(state);
    const found = data.nodes.filter(n => n.id === id || n.owner === id);
    registryStatus(found.length ? `${found.length} historical registration(s) observed in public chain records.` :
      'No registration in the recent scan. You can still enter a node address to view its published runs.');
  } catch (err) { registryStatus(`Public NodeRegistry history unavailable: ${err.message}`); }
  finally { $('activity-registry-lookup').disabled = false; }
}
async function discover(state) {
  const button = $('activity-discover'); button.disabled = true;
  registryStatus('Reading recent public NodeRegistry transactions…');
  try {
    const data = await scanRegistry(state);
    registryStatus(`${data.nodes.length} historical registration(s) found across ${data.scanned} calls ` +
      `(${data.pages} pages). This is not a complete list or a current-registration check.`);
  } catch (err) { registryStatus(`Public NodeRegistry history unavailable: ${err.message}. Run history remains usable.`); }
  finally { button.disabled = false; }
}

function filtersFromControls(state) {
  const period = $('activity-range').value;
  const bounds = rangeBounds(period, Date.now(), $('activity-from').value, $('activity-to').value);
  const ownerFilter = aeAddress($('activity-account-filter').value, ['ak_']);
  const nodeChoice = $('activity-node').value;
  let nodeIds = [];
  if (state.scope === 'node') nodeIds = state.targetNode ? [state.targetNode] : [];
  // Discover deliberately scans the public network, never silently the local node.
  if (state.scope === 'followed') {
    nodeIds = nodeChoice === 'all' ? state.followed.slice() : (state.followed.includes(nodeChoice) ? [nodeChoice] : []);
  }
  const account = state.scope === 'account' ? state.accountTarget : ownerFilter;
  return {nodeIds, account, status: $('activity-status-filter').value,
    feature: text($('activity-feature').value), tags: parseTagFilter($('activity-tags').value),
    ...bounds};
}
function pageLimit() {
  const n = Number($('activity-limit').value) || 50;
  return Math.min(SOURCE_PAGE_LIMIT, Math.max(10, n));
}
function scanSources(state) {
  const f = filtersFromControls(state);
  const limit = pageLimit(), token = config().token;
  const build = (path, trustedContractScope) => ({path, trustedContractScope, next: path, done: false, error: null, visited: new Set()});
  // The /contracts/calls index describes *internal* calls, NOT the ordinary
  // ContractCallTx/PayingForTx that publish DamageBDD reports. Use the actual
  // transaction index; retain the legacy payer's account activities as well.
  const contractPath = `/v3/transactions?contract=${encodeURIComponent(token)}&type=contract_call&type=paying_for&direction=backward&limit=${limit}`;
  const accountPath = (id, owned = false) => `/v3/accounts/${encodeURIComponent(id)}/activities?owned_only=${owned}&type=transactions&direction=backward&limit=${limit}`;
  // When a node submits the PayingForTx on behalf of a user, the outer
  // transaction might not be owned by the user. Search both indices.
  if (state.scope === 'account') return f.account ?
    [build(contractPath, true), build(accountPath(f.account), false)] : [];
  // Discover always scans recent public token transactions, regardless of the
  // local selected node. Users can choose a node from a result afterward.
  if (state.scope === 'discover') return [build(contractPath, true)];
  if (!f.nodeIds.length) return [];
  const sources = [build(contractPath, true)];
  // Preserve the original, working node-payer transaction activity path.
  // This catches wrapped transactions omitted by a generic contract index.
  for (const id of f.nodeIds.slice(0, 8)) {
    if (id.startsWith('ak_')) sources.push(build(accountPath(id, true), false));
  }
  return sources;
}
function updateHistoryUrl(state) {
  try {
    const url = new URL(location.href);
    for (const [key, value] of [
      ['rh_scope', state.scope], ['rh_node', state.targetNode],
      ['rh_account', state.accountTarget], ['rh_range', $('activity-range').value],
      ['rh_feature', $('activity-feature').value], ['rh_tags', $('activity-tags').value],
      ['rh_status', $('activity-status-filter').value]
    ]) { if (value) url.searchParams.set(key, value); else url.searchParams.delete(key); }
    history.replaceState(history.state, '', url);
  } catch { /* History unavailable in embedded preview. */ }
}
function readHistoryUrl(state) {
  try {
    const params = new URLSearchParams(location.search);
    const scope = params.get('rh_scope');
    if (['node', 'account', 'followed', 'discover'].includes(scope)) {
      state.scope = scope;
      state.explicitScope = true;
    }
    const address = aeAddress(params.get('rh_node') || params.get('node'));
    const account = aeAddress(params.get('rh_account') || params.get('account'), ['ak_']);
    if (address) state.targetNode = address;
    if (account) state.accountTarget = account;
    for (const [key, name, values] of [
      ['rh_range', 'activity-range', ['24h', '7d', '30d', 'all', 'custom']],
      ['rh_status', 'activity-status-filter', ['all', 'passed', 'failed', 'unknown']]
    ]) { if (values.includes(params.get(key))) $(name).value = params.get(key); }
    $('activity-feature').value = params.get('rh_feature') || '';
    $('activity-tags').value = params.get('rh_tags') || '';
  } catch { /* Untrusted URL parameters must not break the page. */ }
}
// Public reads prefer AEMDW directly. The same-origin activity proxy is an
// optional deployment compatibility fallback, not required for history.
// Cache a missing route so old nodes don't repeatedly issue 404 requests.
let activityProxyAvailable = true;
async function fetchActivity(url) {
  try { return await fetchPublic(url); }
  catch (remoteError) {
    if (!activityProxyAvailable) throw remoteError;
    const parsed = new URL(url);
    const mdw = new URL(config().mdw);
    if (parsed.origin !== mdw.origin) throw remoteError;
    try {
      return await fetchPublic(`/api/run-history/activities?path=${encodeURIComponent(parsed.pathname + parsed.search)}`);
    } catch (proxyError) {
      if (/HTTP (404|400)/.test(String(proxyError?.message))) activityProxyAvailable = false;
      throw remoteError;
    }
  }
}
async function getTx(state, hash) {
  if (!state.txCache.has(hash)) {
    const job = fetchActivity(middlewareUrl(config().mdw, `/v3/transactions/${encodeURIComponent(hash)}`))
      .catch(() => null);
    state.txCache.set(hash, job);
  }
  return state.txCache.get(hash);
}
async function readMeta(state, cid) {
  if (!state.metaCache.has(cid)) {
    // Read immutable CID/run.meta through this node's existing damage_reports
    // route. A 404 means legacy metadata is absent, not that the run vanished.
    const job = fetchPublic(reportUrl(cid) + 'run.meta', {as: 'json'})
      .then(meta => meta && typeof meta === 'object' && !Array.isArray(meta) ? meta : null)
      .catch(() => null);
    state.metaCache.set(cid, job);
  }
  return state.metaCache.get(cid);
}
async function readFeature(state, cid) {
  if (!state.featureCache.has(cid)) {
    // The already-exposed /features/:hash route calls this node's damage_ipfs.
    // Never issue cross-origin ipfs.io requests, even if an old page injected
    // a window.DamageActivity.ipfsGateway value.
    const job = fetchPublic(featureUrl(cid), {as: 'text', accept: 'text/plain'})
      .then(parseFeature).catch(() => ({title: '', tags: []}));
    state.featureCache.set(cid, job);
  }
  return state.featureCache.get(cid);
}
async function readLegacyStatus(state, cid) {
  if (!state.statusCache.has(cid)) {
    const job = (async () => {
      try {
        const listing = await fetchPublic(reportUrl(cid), {accept: 'application/json'});
        if (!Array.isArray(listing)) return 'unknown';
        const file = listing.map(item => typeof item === 'string' ? item :
          String(item?.Name || item?.name || '')).find(n => /^[\w.\-]+\.plain\.txt$/.test(n));
        if (!file) return 'unknown';
        const body = await fetchPublic(reportUrl(cid) + encodeURIComponent(file),
          {as: 'text', accept: 'text/html'});
        return parseLegacyStatus(body);
      } catch { return 'unknown'; }
    })();
    state.statusCache.set(cid, job);
  }
  return state.statusCache.get(cid);
}
async function enrich(state, row) {
  let run = normalizeRunMeta(row, await readMeta(state, row.reportCid));
  if (!run.featureTitle || !run.evidenceLoaded ||
      (parseTagFilter($('activity-tags').value).length && (!run.tags || !run.tags.length))) {
    const feature = await readFeature(state, row.featureCid);
    if (!run.featureTitle) run.featureTitle = feature.title;
    if (!run.tags?.length) run.tags = feature.tags;
  }
  if (run.status === 'unknown' &&
      ($('activity-status-filter').value !== 'all' || !run.evidenceLoaded)) {
    run.status = await readLegacyStatus(state, row.reportCid);
  }
  return run;
}
async function normalizeTxRow(state, item, source) {
  const opts = {contract: config().token, trustedContractScope: source.trustedContractScope};
  // Avoid requesting full details for unrelated node transactions (channel
  // creations, transfers, etc). Previously a single 50-row page could trigger
  // 50 additional HTTP requests despite containing no verification runs.
  if (!plausibleRunTransaction(item, config().token)) return null;
  let row = normalizeSpend(item, opts);
  const hash = txHashOf(item);
  if (!row && hash) {
    const full = await getTx(state, hash);
    if (full) row = normalizeSpend(full, opts) || normalizeSpend(
      {...full, payload: {tx: item}}, opts);
  }
  if (!row) return null;
  // Transaction pages sometimes omit the enclosing caller/time information.
  // Hydrate missing fields before applying account or time filters.
  if (hash && (!row.callerId || !row.createdMs)) {
    const full = await getTx(state, hash);
    if (full) {
      const combined = {...full, ...item, tx: full.tx || item.tx,
        micro_time: item.micro_time || full.micro_time};
      const hydrated = normalizeSpend(combined, opts);
      if (hydrated) row = {
        ...row, ...hydrated, txHash: hash,
        callerId: hydrated.callerId || row.callerId,
        nodePublicKey: hydrated.nodePublicKey || row.nodePublicKey,
        createdMs: hydrated.createdMs || row.createdMs
      };
    }
  }
  if (!row.txHash) row.txHash = hash;
  return row;
}
function showLoading(state, waiting) {
  state.loading = waiting;
  const next = $('run-reports-next');
  next.disabled = waiting;
  next.textContent = waiting ? 'Loading…' : 'Load more runs';
  $('activity-refresh').disabled = waiting;
}
function updatePager(state) {
  const next = $('run-reports-next'), info = $('run-reports-info');
  const more = state.sources.some(s => !s.done);
  next.hidden = !more;
  next.disabled = state.loading;
  info.textContent = `${state.scannedTransactions} transactions scanned · ${state.rows.length} runs decoded · ${state.sources.filter(s => s.done).length}/${state.sources.length} sources exhausted`;
}

function renderRun(row, ul, state) {
  const li = node('li', 'activity-item');
  const left = node('div', 'activity-left');
  left.append(node('time', 'activity-time', formatTime(row.createdMs)));
  const badge = node('span', `history-status ${row.status}`, row.status === 'passed' ? '✓ Passed' :
    row.status === 'failed' ? '✕ Failed' : 'Result unknown');
  left.append(badge);
  const main = node('div', 'activity-main');
  main.append(node('h3', 'activity-title', row.featureTitle || compact(row.featureCid, 15)));
  if (row.tags?.length) {
    const tags = node('div', 'history-run-tags');
    for (const tag of row.tags.slice(0, 12)) tags.append(node('span', '', tag));
    main.append(tags);
  }
  const meta = node('div', 'activity-meta');
  meta.append(safeLink('Report', reportUrl(row.reportCid)), safeLink('Feature', featureUrl(row.featureCid)));
  if (row.txHash) meta.append(safeLink('Transaction', publicTxUrl(row.txHash)));
  if (row.callerId) meta.append(safeLink(`Account ${compact(row.callerId)}`, accountUrl(row.callerId)));
  if (row.nodePublicKey) meta.append(safeLink(
    `${row.nodeSource === 'report_manifest' ? 'Reported node' : 'Node'} ${compact(row.nodePublicKey)}`,
    accountUrl(row.nodePublicKey)));
  if (row.callerId) {
    const accountRuns = node('button', 'workspace-button history-view-account', 'View account runs');
    accountRuns.type = 'button';
    accountRuns.addEventListener('click', () => {
      state.accountTarget = row.callerId;
      $('activity-account').value = row.callerId;
      fillKnownAccounts(state);
      setScope(state, 'account');
    });
    meta.append(accountRuns);
  }
  main.append(meta);
  const details = node('details', 'activity-details');
  const toggle = node('summary', '', `${tokenAmount(row.amountRaw)} · Evidence details`);
  details.append(toggle);
  const data = node('dl', 'history-run-details');
  for (const [key, value] of [
    ['Node', row.nodePublicKey || 'Not decoded'], ['Account', row.callerId || 'Not indexed'],
    ['Feature CID', row.featureCid], ['Report CID', row.reportCid],
    ['Transaction', row.txHash || 'Not indexed'], ['Run ID', row.runId || 'Legacy'],
    ['Node evidence', row.nodeSource === 'report_manifest' ? 'Claimed by IPFS run.meta (not chain-verified)' :
      row.nodePublicKey ? 'On-chain decoded arguments' : 'Not decoded'],
    ['Spend evidence', row.spendEvidence === 'token_calldata' ? 'CID strings recovered from token calldata (best effort)' :
      'Decoded token spend arguments'],
    ['Duration', row.duration ? `${row.duration.toFixed(2)} s` : 'Not recorded']
  ]) { data.append(node('dt', '', key), node('dd', '', value)); }
  details.append(data); main.append(details);
  li.append(left, main); ul.append(li);
}
function renderRuns(state) {
  const ul = $('run-reports-list'); ul.replaceChildren();
  const filters = filtersFromControls(state);
  const visible = state.rows.filter(r => matchesRun(r, filters))
    .sort((a, b) => (b.createdMs || 0) - (a.createdMs || 0));
  for (const r of visible) renderRun(r, ul, state);
  $('activity-count').textContent = `${visible.length} shown`;
  if (!visible.length) {
    const reason = state.loading ? 'Loading public verification runs…' :
      state.sources.some(s => !s.done) ?
      'No matching runs in the scanned pages. Load more to continue searching.' :
      'No published runs match these filters in the retrieved activity.';
    const message = node('li', 'history-empty', reason);
    ul.append(message);
  }
  updatePager(state);
}
function activePanel() { const panel = $('activity-tab'); return !!panel && !panel.hidden; }
function startSearch(state) {
  updateHistoryUrl(state);
  state.version += 1;
  // Supersede in-flight scans; old completions check the generation before render.
  showLoading(state, false);
  state.sources = scanSources(state); state.rows = []; state.seen.clear();
  state.scannedTransactions = 0; state.undecodedCalls = 0;
  const f = filtersFromControls(state);
  if (f.from != null && f.to != null && f.from > f.to) {
    status('The start time must be before the end time.'); renderRuns(state); return;
  }
  if (!state.sources.length) {
    status(state.scope === 'account' ? 'Choose an account to view its public activity.' :
      state.scope === 'followed' ? 'Follow a public node to begin.' :
      "This node’s public ID is unavailable. Use My account or browse nodes below.");
    renderRuns(state); return;
  }
  status(state.scope === 'discover' && !filtersFromControls(state).nodeIds.length ?
    'Loading recent public network runs (not scoped to this node)…' :
    'Loading public run evidence…');
  if (activePanel()) loadMore(state);
  else renderRuns(state);
}
async function loadMore(state) {
  if (state.loading || !activePanel()) return;
  const version = state.version;
  if (!state.sources.some(s => !s.done)) return;
  showLoading(state, true);
  renderRuns(state);
  const errors = [];
  // One user action makes bounded forward progress even if the first pages
  // contain no runs. This replaces the old one-page-at-a-time dead-end.
  for (let round = 0; round < AUTO_SCAN_PAGES; round++) {
    if (version !== state.version) return;
    const active = state.sources.filter(s => !s.done);
    if (!active.length) break;
    const batches = await Promise.all(active.map(async source => {
      try {
        const url = middlewareUrl(config().mdw, source.next);
        if (source.visited.has(url)) return {source, rows: [], next: null, error: new Error('Repeated middleware cursor')};
        const page = await fetchActivity(url);
        source.visited.add(url); // Keep failed cursors retryable.
        const rows = Array.isArray(page?.data) ? page.data : [];
        let next = page?.next ? middlewareUrl(config().mdw, page.next) : null;
        if (next === url) next = null; // A valid next cursor can follow an empty page.
        return {source, rows, next};
      } catch (error) { return {source, rows: [], next: source.next, error}; }
    }));
    if (version !== state.version) return;
    for (const batch of batches) {
      batch.source.next = batch.next;
      batch.source.done = !batch.next;
      batch.source.error = batch.error || null;
      state.scannedTransactions += batch.rows.length;
      if (batch.error) errors.push(batch.error);
    }
    const candidates = batches.flatMap(b => b.rows.map(row => ({row, source: b.source})))
      .filter(({row}) => plausibleRunTransaction(row, config().token));
    const discovered = [];
    await taskQueue(candidates, TX_PARALLEL, async ({row, source}) => {
      const found = await normalizeTxRow(state, row, source).catch(() => null);
      if (found) discovered.push(found);
      else if (JSON.stringify(row).includes('call_data')) state.undecodedCalls++;
    });
    if (version !== state.version) return;
    const f = filtersFromControls(state);
    // The same tx may appear in both token-contract and node-account indices.
    // Prefer the candidate with *decoded* chain identities over an incomplete
    // calldata fallback. Otherwise the first result can hide a real node run.
    const distinct = new Map();
    const score = row => (row.nodePublicKey ? 4 : 0) + (row.callerId ? 2 : 0) +
      (row.amountRaw ? 1 : 0) + (row.createdMs ? 1 : 0);
    for (const row of discovered) {
      const key = row.txHash || `${row.reportCid}:${row.callerId}:${row.nodePublicKey}`;
      if (state.seen.has(key)) continue;
      if (!distinct.has(key) || score(row) > score(distinct.get(key))) distinct.set(key, row);
    }
    const fresh = [...distinct.values()];
    await taskQueue(fresh, EVIDENCE_PARALLEL, async (row, i) => {
      fresh[i] = await enrich(state, row).catch(() => row);
    });
    if (version !== state.version) return;
    const matched = fresh.filter(row =>
      (!f.nodeIds.length || f.nodeIds.includes(row.nodePublicKey)) &&
      (!f.account || row.callerId === f.account));
    state.rows.push(...matched);
    for (const row of matched) {
      state.seen.add(row.txHash || `${row.reportCid}:${row.callerId}:${row.nodePublicKey}`);
      if (row.callerId) state.knownAccounts.add(row.callerId);
      if (row.nodePublicKey && !state.registryNodes.has(row.nodePublicKey)) {
        state.registryNodes.set(row.nodePublicKey,
          {id: row.nodePublicKey, name: row.nodePublicKey, source: 'public_spend'});
      }
    }
    fillNodeOptions(state); renderRegistryNodes(state); fillKnownAccounts(state);
    // Show runs found so far; only stop early once meaningful evidence is visible.
    renderRuns(state);
    const visible = state.rows.filter(r => matchesRun(r, f)).length;
    if (visible >= 10 || errors.length) break;
  }
  if (version !== state.version) return;
  showLoading(state, false);
  renderRuns(state);
  const more = state.sources.some(s => !s.done);
  const summary = `${state.rows.length} run(s) from ${state.scannedTransactions} public transactions`;
  if (errors.length) {
    status(`${summary}. ${errors.length} source(s) failed (${errors[0]?.message || 'Network unavailable'}). Retry to continue.`);
  } else if (!state.rows.length && state.undecodedCalls) {
    status(`${summary}. ${state.undecodedCalls} candidate call(s) could not be decoded into report CIDs; older runs may require ABI decoding. Older pages may remain.`);
  } else if (!state.rows.length && !more) {
    status(`No published DAMAGE runs found among ${state.scannedTransactions} scanned transactions. Try another scope or date range.`);
  } else {
    status(`${summary}.${more ? ' Older pages remain — Load more to continue.' : ' All fetched pages exhausted.'}`);
  }
}

function triggerSearch(state) {
  clearTimeout(state.inputTimer);
  state.inputTimer = setTimeout(() => {
    // Do not send a malformed account to the public middleware.
    const account = text($('activity-account').value);
    const runner = text($('activity-account-filter').value);
    if (state.scope === 'account' && account && !aeAddress(account, ['ak_'])) {
      status('Enter a valid public ak_ account ID.'); return;
    }
    if (runner && !aeAddress(runner, ['ak_'])) {
      status('Enter a valid ak_ runner account filter.'); return;
    }
    state.accountTarget = aeAddress(account, ['ak_']) || state.owner;
    startSearch(state);
  }, 300);
}
function setupInteractions(state) {
  for (const button of document.querySelectorAll('[data-history-scope]')) {
    button.addEventListener('click', () => {
      state.explicitScope = true;
      if (button.dataset.historyScope === 'discover') discover(state);
      setScope(state, button.dataset.historyScope);
    });
  }
  $('activity-node').addEventListener('change', e => {
    if (state.scope === 'followed' && e.target.value === 'all') { startSearch(state); return; }
    state.targetNode = aeAddress(e.target.value); startSearch(state);
  });
  $('activity-node-use').addEventListener('click', () => {
    const id = aeAddress($('activity-node-manual').value);
    if (!id) { status('Enter a valid public node address.'); return; }
    state.registryNodes.set(id, state.registryNodes.get(id) || {id, name: id});
    viewNode(state, id);
    registryStatus('Showing published on-chain runs for this public node. ' +
      'Following it does not require a registry lookup.');
  });
  $('activity-registry-lookup').addEventListener('click', () => doRegistryLookup(state));
  $('activity-registry-query').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); doRegistryLookup(state); }
  });
  $('activity-discover').addEventListener('click', () => discover(state));
  $('activity-account').addEventListener('change', () => triggerSearch(state));
  $('activity-account-known').addEventListener('change', e => {
    const selected = aeAddress(e.target.value, ['ak_']);
    if (!selected) return;
    $('activity-account').value = selected;
    state.accountTarget = selected;
    setScope(state, 'account');
  });
  $('activity-account-filter').addEventListener('change', () => triggerSearch(state));
  for (const id of ['activity-feature', 'activity-tags', 'activity-account-filter', 'activity-account']) {
    $(id).addEventListener('input', () => triggerSearch(state));
  }
  for (const id of ['activity-status-filter', 'activity-limit', 'activity-range', 'activity-from', 'activity-to']) {
    $(id).addEventListener('change', () => {
      const custom = $('activity-range').value === 'custom';
      $('activity-from-wrap').hidden = !custom;
      $('activity-to-wrap').hidden = !custom;
      startSearch(state);
    });
  }
  $('activity-refresh').addEventListener('click', () => startSearch(state));
  $('run-reports-next').addEventListener('click', () => loadMore(state));
  document.addEventListener('damage:panelchange', e => {
    if (e.detail?.id !== 'activity-tab') return;
    state.ready = true;
    if (!state.sources.length) startSearch(state);
    else if (!state.rows.length && !state.loading) loadMore(state);
  });
  document.addEventListener('auth:changed', event => {
    syncAccount(state, event.detail?.authenticated ? event.detail.address : null);
  });
  document.addEventListener('node:unlocked', event => {
    const id = aeAddress(event.detail?.public_key || event.detail?.node_public_key, ['ak_']);
    if (!id) return;
    state.localNode = id;
    if (!state.targetNode) state.targetNode = id;
    addRegistryNodes(state, [{id, name: 'This node'}]);
    if (!state.explicitScope) setScope(state, 'node');
  });
}

// Session restores asynchronously. Keep public history in sync with the
// authenticated AE address without mixing it up with the executing node ID.
function syncAccount(state, address) {
  const account = aeAddress(address, ['ak_']);
  if (state.owner === account) return;
  const previous = state.owner;
  state.owner = account;
  state.followed = loadFollowed(account);
  $('activity-follow-count').textContent = state.followed.length ? `(${state.followed.length})` : '';
  if (!state.accountTarget || state.accountTarget === previous) {
    state.accountTarget = account;
    $('activity-account').value = account;
  }
  if (account) state.knownAccounts.add(account);
  fillKnownAccounts(state);
  fillNodeOptions(state);
  if (!state.localNode && !state.explicitScope && account && state.scope === 'discover') {
    setScope(state, 'account');
  } else if (state.scope === 'account' && activePanel()) {
    startSearch(state);
  }
  // NodeRegistry discovery is intentionally lazy; run history needs no registry read.
}

export function initRunHistory() {
  const host = $('run-history-workspace');
  if (!host || host.dataset.bound) return null;
  host.dataset.bound = '1';
  const state = createState(host);
  readHistoryUrl(state);
  $('activity-account').value = state.accountTarget;
  $('activity-node-manual').value = state.targetNode;
  $('activity-follow-count').textContent = state.followed.length ? `(${state.followed.length})` : '';
  setupInteractions(state);
  setScope(state, state.scope, {refresh: false});
  addRegistryNodes(state, state.followed.map(id => ({id, name: id})));
  renderRegistryNodes(state);
  fillKnownAccounts(state);
  // Read the historical registry only when the user opens node discovery.
  // Run history is independent of NodeRegistry lookups; discovery is optional.
  // Start the first read whenever the history panel is already displayed,
  // including direct #activity-tab navigation that ran before this module.
  if (activePanel()) { state.ready = true; startSearch(state); }
  // TokenManager.ready resolves after /accounts/session and emits auth:changed.
  // Resolve again here in case its initial event preceded our listener.
  Promise.resolve(TokenManager.ready).then(() => {
    syncAccount(state, TokenManager.getAddress());
    if (activePanel() && !state.ready) { state.ready = true; startSearch(state); }
  }).catch(() => {});
  // Compatibility for the existing global Reports API; used by other tabs.
  window.Reports = {
    renderRunReports: async (id, {wallet = null} = {}) => {
      // main.js historically passes the *wallet/account* as id here; it is
      // never the executing node identity. Do not overwrite the node default.
      const account = aeAddress(wallet || id, ['ak_']);
      if (account) {
        syncAccount(state, account);
        state.accountTarget = account;
        state.knownAccounts.add(account);
        $('activity-account').value = account;
        fillKnownAccounts(state);
        fillNodeOptions(state);
      }
      if (state.scope === 'account' && account) startSearch(state);
    },
    renderPage: () => startSearch(state)
  };
  return state;
}

if (document.readyState === 'loading')
  document.addEventListener('DOMContentLoaded', initRunHistory, {once: true});
else initRunHistory();
