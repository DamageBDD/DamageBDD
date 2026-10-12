/* DamageBDD Run history — public, read-only, registry-aware.
 * Sources: NodeRegistry via same-origin read-only endpoint; AEMDW public
 * transactions; immutable run.meta/feature/report artifacts via IPFS.
 * Nothing here reads a browser auth token, wallet key or private run context.
 */
import {
  aeAddress, isCid, txHashOf, normalizeSpend, parseFeature, normalizeRunMeta,
  parseLegacyStatus, parseTagFilter, rangeBounds, matchesRun, middlewareUrl,
  DEFAULT_TOKEN_CONTRACT, DEFAULT_MDW, DEFAULT_GATEWAY
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
const TX_PARALLEL = 8;
const EVIDENCE_PARALLEL = 6;
const MAX_BYTES = 128 * 1024;
const DEFAULT_SCOPE = 'node';

function localPreferences() {
  return {scope: DEFAULT_SCOPE, range: '7d'};
}
function config() {
  return {
    mdw: window.DamageActivity?.mdwBase || DEFAULT_MDW,
    ipfs: window.DamageActivity?.ipfsGateway || DEFAULT_GATEWAY,
    token: window.DamageActivity?.damageTokenContract || DEFAULT_TOKEN_CONTRACT
  };
}
function ipfsUrl(cid, path = '') {
  const root = config().ipfs.replace(/\/+$/, '') + '/' + encodeURIComponent(cid);
  return path ? root + '/' + path.split('/').map(encodeURIComponent).join('/') : root;
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
async function firstSuccessful(loaders) {
  let error;
  for (const run of loaders) {
    try { return await run(); } catch (e) { error = e; }
  }
  throw error || new Error('No evidence source available');
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
    version: 0, loading: false, ready: false, range: prefs.range, explicitScope: false
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
    'Discover registered nodes' : 'Browse node registry';
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
    registryStatus('No followed nodes yet. Look up a node, then choose Follow.');
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
  if (!state.followed.includes(id) && !state.registryNodes.get(id)?.registered) {
    registryStatus('Verify this node using NodeRegistry before following.');
    return;
  }
  if (!state.followed.includes(id)) state.followed.push(id);
  else state.followed = state.followed.filter(x => x !== id);
  saveFollowed(state);
  $('activity-follow-count').textContent = state.followed.length ? `(${state.followed.length})` : '';
  fillNodeOptions(state); renderRegistryNodes(state);
  if (state.scope === 'followed') startSearch(state);
}
function viewNode(state, id) {
  state.targetNode = id;
  $('activity-node-manual').value = id;
  setScope(state, state.scope === 'account' ? 'node' : state.scope);
}
function renderRegistryNodes(state) {
  const ul = $('activity-node-results'); if (!ul) return;
  ul.replaceChildren();
  for (const n of [...state.registryNodes.values()]) {
    const li = node('li', 'history-node');
    const info = node('div', 'history-node-info');
    info.append(node('strong', '', n.name && n.name !== n.id ? n.name :
      n.registered ? 'Registered node' : n.id === state.localNode ? 'This node (unverified)' : 'Unverified node'));
    info.append(node('code', '', compact(n.id, 12)));
    if (n.location || n.version) info.append(node('small', '', [n.location, n.version].filter(Boolean).join(' · ')));
    li.append(info);
    const actions = node('div', 'history-node-actions');
    const open = node('button', 'workspace-button', 'View runs'); open.type = 'button';
    open.addEventListener('click', () => viewNode(state, n.id));
    const toggle = node('button', 'workspace-button', state.followed.includes(n.id) ? 'Following ✓' : '+ Follow');
    toggle.type = 'button'; toggle.setAttribute('aria-pressed', String(state.followed.includes(n.id)));
    toggle.disabled = !state.followed.includes(n.id) && !n.registered;
    if (toggle.disabled) toggle.title = 'Lookup and verify this node before following';
    toggle.addEventListener('click', () => follow(state, n.id));
    actions.append(open, toggle); li.append(actions); ul.append(li);
  }
}
async function queryRegistry(state, query) {
  const params = new URLSearchParams(query);
  const data = await fetchPublic(`/api/run-history/nodes?${params.toString()}`);
  if (!Array.isArray(data?.nodes)) throw new Error(data?.error || 'Invalid registry reply');
  addRegistryNodes(state, data.nodes);
  renderRegistryNodes(state);
  return data;
}
async function ownerLookup(state, owner, {quiet = false} = {}) {
  const account = aeAddress(owner, ['ak_']); if (!account) return;
  if (!quiet) registryStatus('Looking up operator nodes on the registry…');
  try {
    const data = await queryRegistry(state, {owner: account});
    if (!quiet) registryStatus(`${data.nodes.length} currently registered node(s) for ${compact(account)}.`);
    return data.nodes;
  } catch (err) {
    if (!quiet) registryStatus(`Registry lookup failed: ${err.message}`);
    return null;
  }
}
async function doRegistryLookup(state) {
  const id = aeAddress($('activity-registry-query').value);
  if (!id) { registryStatus('Enter a valid ak_ account or ak_/ct_ node ID.'); return; }
  $('activity-registry-lookup').disabled = true;
  try {
    let found = null;
    if (id.startsWith('ak_')) found = await ownerLookup(state, id, {quiet: true});
    if (!found?.length) {
      const data = await queryRegistry(state, {node: id});
      found = data.nodes;
    }
    registryStatus(found.length ? `${found.length} node(s) verified against NodeRegistry.` : 'No matching registered nodes.');
  } catch (err) { registryStatus(`Registry lookup failed: ${err.message}`); }
  finally { $('activity-registry-lookup').disabled = false; }
}
async function discover(state) {
  const b = $('activity-discover'); b.disabled = true;
  registryStatus('Scanning recent registry transactions and verifying registered nodes…');
  try {
    const data = await queryRegistry(state, {discover: '1'});
    registryStatus(`${data.nodes.length} verified recently registered node(s) from ${data.scanned} transactions. ` +
      'For an older node, search by owner account or node ID.');
  } catch (e) { registryStatus(`Discovery unavailable: ${e.message}. Search by owner or node ID.`); }
  finally { b.disabled = false; }
}

function filtersFromControls(state) {
  const period = $('activity-range').value;
  const bounds = rangeBounds(period, Date.now(), $('activity-from').value, $('activity-to').value);
  const ownerFilter = aeAddress($('activity-account-filter').value, ['ak_']);
  const nodeChoice = $('activity-node').value;
  let nodeIds = [];
  if (state.scope === 'node' || state.scope === 'discover') nodeIds = state.targetNode ? [state.targetNode] : [];
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
  const build = (path, trustedContractScope) => ({path, trustedContractScope, next: path, done: false, error: null});
  const contractPath = `/v3/transactions?type=contract_call&contract=${encodeURIComponent(token)}&direction=backward&limit=${limit}`;
  const accountPath = id => `/v3/accounts/${encodeURIComponent(id)}/activities?owned_only=false&type=transactions&direction=backward&limit=${limit}`;
  if (state.scope === 'account') return f.account ? [build(accountPath(f.account), false)] : [];
  // When the local node identity is sealed and there is no signed-in account,
  // the Discover scope still loads recent public run activity. Never label
  // these runs as belonging to "This node" until its address is known.
  if (state.scope === 'discover' && !f.nodeIds.length) return [build(contractPath, true)];
  if (!f.nodeIds.length) return [];
  const sources = [build(contractPath, true)];
  // PayingFor outer transactions may be indexed under the node payer rather
  // than the token contract. Include those activities as a second source.
  for (const id of f.nodeIds.slice(0, 8)) {
    if (id.startsWith('ak_')) sources.push(build(accountPath(id), false));
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
// Public reads prefer AEMDW directly. A same-origin, path-restricted read-only
// proxy avoids browsers failing all scans on CORS, corporate firewalls or CSP.
async function fetchActivity(url) {
  try { return await fetchPublic(url); }
  catch (remoteError) {
    const parsed = new URL(url);
    const mdw = new URL(config().mdw);
    if (parsed.origin !== mdw.origin) throw remoteError;
    return fetchPublic(`/api/run-history/activities?path=${encodeURIComponent(parsed.pathname + parsed.search)}`);
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
    const job = firstSuccessful([
      async () => JSON.parse(await fetchPublic(`${reportUrl(cid)}run.meta`, {as: 'text', accept: 'text/html'})),
      async () => JSON.parse(await fetchPublic(ipfsUrl(cid, 'run.meta'), {as: 'text'}))
    ]).catch(() => null);
    state.metaCache.set(cid, job);
  }
  return state.metaCache.get(cid);
}
async function readFeature(state, cid) {
  if (!state.featureCache.has(cid)) {
    const job = firstSuccessful([
      () => fetchPublic(featureUrl(cid), {as: 'text', accept: 'text/plain'}),
      () => fetchPublic(ipfsUrl(cid), {as: 'text'})
    ]).then(parseFeature).catch(() => ({title: '', tags: []}));
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
        const file = listing.map(String).find(n => /^[\w.\-]+\.plain\.txt$/.test(n));
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
  if (run.status === 'unknown' && $('activity-status-filter').value !== 'all') {
    run.status = await readLegacyStatus(state, row.reportCid);
  }
  return run;
}
async function normalizeTxRow(state, item, source) {
  const opts = {contract: config().token, trustedContractScope: source.trustedContractScope};
  let row = normalizeSpend(item, opts);
  const hash = txHashOf(item);
  if (!row && hash) {
    const full = await getTx(state, hash);
    if (full) row = normalizeSpend(full, opts) || normalizeSpend(
      {...full, payload: {tx: item}}, opts);
  }
  if (!row) return null;
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
  info.textContent = `${state.rows.length} public run(s) examined · ${state.sources.filter(s => s.done).length}/${state.sources.length} sources exhausted`;
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
  meta.append(safeLink(`Node ${compact(row.nodePublicKey)}`, accountUrl(row.nodePublicKey)));
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
    ['Node', row.nodePublicKey], ['Account', row.callerId || 'Not indexed'],
    ['Feature CID', row.featureCid], ['Report CID', row.reportCid],
    ['Transaction', row.txHash || 'Not indexed'], ['Run ID', row.runId || 'Legacy'],
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
  const f = filtersFromControls(state);
  if (f.from != null && f.to != null && f.from > f.to) {
    status('The start time must be before the end time.'); renderRuns(state); return;
  }
  if (!state.sources.length) {
    status(state.scope === 'account' ? 'Choose an account to view its public activity.' :
      state.scope === 'followed' ? 'Follow a registered node to begin.' :
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
  const active = state.sources.filter(s => !s.done);
  if (!active.length) return;
  showLoading(state, true);
  renderRuns(state);
  const batches = await Promise.all(active.map(async source => {
    try {
      const url = middlewareUrl(config().mdw, source.next);
      const page = await fetchActivity(url);
      const rows = Array.isArray(page?.data) ? page.data : [];
      let next = page?.next ? middlewareUrl(config().mdw, page.next) : null;
      if (next === source.next || rows.length === 0) next = null;
      return {source, rows, next};
    } catch (error) { return {source, rows: [], next: source.next, error}; }
  }));
  if (version !== state.version) return;
  const errors = batches.filter(b => b.error);
  for (const batch of batches) {
    batch.source.next = batch.next;
    // Keep an errored cursor retryable, rather than treating an HTTP failure
    // as the end of the public run history.
    batch.source.done = !batch.next;
    batch.source.error = batch.error || null;
  }
  const discovered = [];
  await taskQueue(batches.flatMap(b => b.rows.map(row => ({row, source: b.source}))),
    TX_PARALLEL, async ({row, source}) => {
      const found = await normalizeTxRow(state, row, source).catch(() => null);
      if (found) discovered.push(found);
    });
  if (version !== state.version) return;
  const f = filtersFromControls(state);
  const fresh = [];
  for (const row of discovered) {
    if (f.nodeIds.length && !f.nodeIds.includes(row.nodePublicKey)) continue;
    if (f.account && row.callerId && row.callerId !== f.account) continue;
    const key = row.txHash || `${row.reportCid}:${row.callerId}:${row.nodePublicKey}`;
    if (!state.seen.has(key)) { state.seen.add(key); fresh.push(row); }
  }
  await taskQueue(fresh, EVIDENCE_PARALLEL, async (row, i) => {
    fresh[i] = await enrich(state, row).catch(() => row);
  });
  if (version !== state.version) return;
  state.rows.push(...fresh);
  for (const row of fresh) if (row.callerId) state.knownAccounts.add(row.callerId);
  fillKnownAccounts(state);
  showLoading(state, false); renderRuns(state);
  const more = state.sources.some(s => !s.done);
  if (errors.length) {
    const message = errors[0].error?.message || 'Network unavailable';
    status(`${state.rows.length} public run(s) examined. ${errors.length} source(s) failed (${message}). Retry Refresh or Load more.`);
  } else if (!state.rows.length && !more) {
    status('No published DAMAGE runs found in these transactions. Change the scope or time range.');
  } else {
    status(`${state.rows.length} public run(s) examined.${more ? ' More pages available.' : ' End of retrieved activity.'}`);
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
    // Verify asynchronously. Unregistered IDs may still have historical
    // published activity, but only verified IDs join registry discovery.
    queryRegistry(state, {node: id}).then(data => registryStatus(data.nodes.length ?
      'Node verified by registry.' : 'Node not registered; displaying public activity only.'))
      .catch(() => registryStatus('Node lookup could not be verified; displaying public activity only.'));
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
  if (account) ownerLookup(state, account, {quiet: true});
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
  // Show nodes owned by the signed-in account without requiring a private API.
  if (state.owner) ownerLookup(state, state.owner, {quiet: true}).then(() => renderRegistryNodes(state));
  if (state.localNode) queryRegistry(state, {node: state.localNode})
    .then(() => renderRegistryNodes(state)).catch(() => {});
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
