/* Pure normalization/filter functions shared by run history and its Node tests. */
export const DEFAULT_TOKEN_CONTRACT = 'ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk';
export const DEFAULT_MDW = 'https://mainnet.aeternity.io/mdw';
// NodeRegistry v2 deployment used by damage_node_registry.erl; override per network.
export const DEFAULT_REGISTRY_CONTRACT = 'ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ';

export function aeAddress(id, prefixes = ['ak_', 'ct_']) {
  const text = String(id ?? '').trim();
  return prefixes.some(p => text.startsWith(p)) &&
    /^(ak|ct)_[1-9A-HJ-NP-Za-km-z]{20,70}$/.test(text) ? text : '';
}

export function isCid(v) {
  const s = String(v ?? '').trim();
  return /^Qm[1-9A-HJ-NP-Za-km-z]{44}$/.test(s) || /^bafy[a-z2-7]{20,}$/i.test(s);
}

function valueOf(v) {
  if (v && typeof v === 'object' && !Array.isArray(v)) return Object.hasOwn(v, 'value') ? v.value : v;
  if (Array.isArray(v) && v.length === 2 && typeof v[0] === 'string') return v[1];
  return v;
}
function txt(v) { return String(valueOf(v) ?? '').trim(); }
function txCandidates(root) {
  const seen = new Set(), pending = [root], out = [];
  while (pending.length && out.length < 22) {
    const x = pending.shift();
    if (!x || typeof x !== 'object' || seen.has(x)) continue;
    seen.add(x); out.push(x);
    for (const k of ['payload', 'tx', 'transaction', 'inner_tx', 'internal_tx', 'call_info', 'call']) {
      if (x[k] && typeof x[k] === 'object') pending.push(x[k]);
    }
  }
  return out;
}
/** Decide whether it is worth hydrating an activity row with /transactions/:hash.
 * AEMDW account activity pages contain many completely unrelated transactions.
 * Unknown shapes remain eligible: missing a type must not hide historical runs.
 */
export function plausibleRunTransaction(root, contract = DEFAULT_TOKEN_CONTRACT) {
  const candidates = txCandidates(root);
  if (candidates.some(x => {
    const a = argsOf(x);
    return a.length >= 4 && isCid(txt(a[2])) && isCid(txt(a[3])) &&
      (!contractOf(x) || contractOf(x) === contract);
  })) return true;
  if (candidates.some(x => {
    const name = methodName(x);
    return name === 'spend' && (!contractOf(x) || contractOf(x) === contract);
  })) return true;
  const wrapped = candidates.some(x => /(?:paying.?for|ga.?meta)/i.test(txt(x?.type ?? x?.tx_type ?? x?.kind)));
  // Plain calls to *other* contracts cannot be DAMAGE token spends. Do not
  // hydrate all unrelated application traffic under a node payer account.
  if (!wrapped && candidates.some(x =>
    /contract.?call/i.test(txt(x?.type ?? x?.tx_type ?? x?.kind)) &&
    contractOf(x) && contractOf(x) !== contract) &&
    !candidates.some(x => contractOf(x) === contract)) return false;
  const kinds = candidates.flatMap(x => [x.type, x.tx_type, x.kind])
    .filter(v => typeof v === 'string' && v).map(v => v.toLowerCase());
  if (kinds.some(v => /(?:contract.?call|paying.?for|ga.?meta|internalcontractcall)/.test(v)))
    return true;
  // A token-scoped transaction can be a wrapped call; inspect if the token is
  // mentioned even if the outer event type doesn't expose the inner call.
  if (candidates.some(x => contractOf(x) === contract)) return true;
  return kinds.length === 0;
}

export function txHashOf(row) {
  for (const x of txCandidates(row)) {
    for (const k of ['hash', 'tx_hash', 'call_tx_hash']) {
      if (typeof x[k] === 'string' && x[k].startsWith('th_')) return x[k];
    }
  }
  return '';
}
function methodName(x) {
  const name = txt(x?.function ?? x?.function_name ?? x?.func ?? x?.entrypoint ?? x?.call_name);
  return name.split('.').pop();
}
function argsOf(x) {
  for (const key of ['arguments', 'args', 'decoded_args']) {
    if (Array.isArray(x[key])) return x[key].map(valueOf);
  }
  return [];
}
function contractOf(x) { return txt(x?.contract_id ?? x?.contract ?? x?.recipient_id); }
/** The public middleware can expose an encoded cb_ call_data rather than
 * decoded spend arguments. FATE stores string arguments as literal UTF-8
 * bytes. Extract only an ordered pair of valid immutable CIDs; this is a
 * best-effort compatibility fallback, not a full Sophia ABI decoder.
 */
export function cidsFromCallData(callData) {
  if (typeof callData !== 'string' || !/^cb_[A-Za-z0-9+/=]{8,65536}$/.test(callData))
    return [];
  try {
    const bytes = atob(callData.slice(3));
    const matches = bytes.match(/Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]{20,120}/gi) || [];
    const cids = matches.filter(isCid);
    return cids.length === 2 && cids[0] !== cids[1] ? cids : [];
  } catch { return []; }
}

export function timeMs(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return null;
  if (n >= 1e14) return Math.floor(n / 1000); // microseconds
  if (n >= 1e11) return n;                     // milliseconds
  if (n >= 1e9) return n * 1000;               // Unix seconds
  return null;
}
function timestamp(root) {
  for (const x of txCandidates(root)) {
    for (const k of ['micro_time', 'block_time', 'time', 'created_at']) {
      const n = timeMs(x[k]);
      if (n) return n;
    }
  }
  return null;
}
function callerOf(candidates) {
  for (const x of candidates) {
    for (const k of ['caller_id', 'sender_id', 'account_id', 'origin']) {
      const v = txt(x[k]);
      if (aeAddress(v, ['ak_'])) return v;
    }
  }
  return '';
}

/** Only accept a spend with two IPFS CIDs and a matching token contract.
 * The `trustedContractScope` flag is used exclusively for responses to the
 * contract-filtered middleware endpoint, never arbitrary account activity.
 */
export function normalizeSpend(root, {contract = DEFAULT_TOKEN_CONTRACT, trustedContractScope = false} = {}) {
  if (!root || typeof root !== 'object') return null;
  const candidates = txCandidates(root);
  for (const candidate of candidates) {
    const args = argsOf(candidate);
    if (args.length < 4 || !isCid(txt(args[2])) || !isCid(txt(args[3]))) continue;
    const observedContract = contractOf(candidate) || candidates.map(contractOf).find(Boolean) || '';
    if (observedContract && observedContract !== contract) continue;
    // Requiring a spend entrypoint avoids interpreting unrelated contract calls
    // as verification runs. Older middleware responses may omit the entrypoint
    // on a query already constrained to the token contract.
    if (methodName(candidate) !== 'spend' && !trustedContractScope && observedContract !== contract) continue;
    const nodePublicKey = aeAddress(txt(args[0]));
    if (!nodePublicKey) continue;
    const caller = callerOf([candidate, ...candidates]);
    return {
      txHash: txHashOf(root), nodePublicKey, callerId: caller,
      featureCid: txt(args[2]), reportCid: txt(args[3]),
      amountRaw: txt(args[1]), createdMs: timestamp(root),
      featureTitle: '', tags: [], status: 'unknown', evidenceLoaded: false
    };
  }
  // Older public transactions often have only cb_ encoded calldata.
  // Trust this fallback ONLY when bound to the configured token contract;
  // the node argument is not decoded, so a newer IPFS run.meta may later
  // provide its claimed node identity without pretending it was verified.
  for (const candidate of candidates) {
    if (methodName(candidate) && methodName(candidate) !== 'spend') continue;
    const observedContract = contractOf(candidate) || candidates.map(contractOf).find(Boolean) || '';
    if ((observedContract && observedContract !== contract) ||
        (!observedContract && !trustedContractScope)) continue;
    const [featureCid, reportCid] = cidsFromCallData(candidate.call_data);
    if (!featureCid || !reportCid) continue;
    return {
      txHash: txHashOf(root), nodePublicKey: '', callerId: callerOf([candidate, ...candidates]),
      featureCid, reportCid, amountRaw: '', createdMs: timestamp(root),
      featureTitle: '', tags: [], status: 'unknown', evidenceLoaded: false,
      nodeSource: 'unresolved', spendEvidence: 'token_calldata'
    };
  }
  return null;
}

/** A historical NodeRegistry.register_node transaction is evidence of a
 * registration at that block, NOT proof that the node is enabled or still
 * owned by the same account. Only parse rows from the registry-scoped query.
 */
export function registryRegistration(root, {registryContract = DEFAULT_REGISTRY_CONTRACT,
    trustedRegistryScope = false} = {}) {
  if (!root || typeof root !== 'object') return null;
  for (const entry of txCandidates(root)) {
    if (methodName(entry) !== 'register_node') continue;
    const args = argsOf(entry);
    if (args.length < 4) continue;
    const knownContract = contractOf(entry);
    if (knownContract && knownContract !== registryContract) continue;
    if (!knownContract && !trustedRegistryScope) continue;
    const owner = aeAddress(txt(args[0]), ['ak_']);
    const id = aeAddress(txt(args[1]));
    if (!owner || !id) continue;
    return {id, owner, name: id, observed: true, registered: false,
      txHash: txHashOf(root)};
  }
  return null;
}

export function parseFeature(text) {
  const source = String(text ?? '');
  const line = source.split(/\r?\n/).find(x => /^\s*Feature\s*:/i.test(x));
  const title = line ? line.replace(/^\s*Feature\s*:\s*/i, '').trim() : '';
  const tags = [...source.matchAll(/^\s*(?:@[\w:.-]+(?:\s+|$))+/gm)].flatMap(m =>
    (m[0].match(/@[\w:.-]+/g) || []).map(t => t.toLowerCase()));
  return {title, tags: [...new Set(tags)]};
}

export function metadataStatus(meta) {
  if (!meta || typeof meta !== 'object') return 'unknown';
  const declared = String(meta.status ?? '').toLowerCase();
  if (declared === 'passed' || declared === 'success') return 'passed';
  if (declared === 'failed' || declared === 'fail' || declared === 'error') return 'failed';
  if (meta.result === 'success') return 'passed';
  if (meta.result && meta.result !== 'unknown') return 'failed';
  return 'unknown';
}

export function normalizeRunMeta(row, meta) {
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) return row;
  const tags = Array.isArray(meta.tags) ? meta.tags.map(x => String(x).trim().toLowerCase()).filter(x => /^@[\w:.-]+$/.test(x)) : row.tags;
  const createdMs = timeMs(meta.start_time_hires ?? meta.completed_at) || row.createdMs;
  const metaNode = aeAddress(meta.node_public_key, ['ak_']);
  const metaAccount = aeAddress(meta.public_key, ['ak_']);
  return {...row,
    featureTitle: String(meta.feature_title || row.featureTitle || ''),
    tags, createdMs, status: metadataStatus(meta), evidenceLoaded: true,
    runId: String(meta.run_id || ''), duration: Number(meta.execution_time_hires || 0),
    nodePublicKey: row.nodePublicKey || metaNode || '',
    callerId: row.callerId || metaAccount || '',
    nodeSource: row.nodePublicKey ? 'chain_arguments' : metaNode ? 'report_manifest' : 'unresolved',
    callerSource: row.callerId ? 'chain_arguments' : metaAccount ? 'report_manifest' : 'unresolved'
  };
}

export function parseLegacyStatus(text) {
  const body = String(text ?? '');
  if (/\b(?:Given|When|Then|And|But)\b[^\r\n]*\b(?:fail|failed|error)\s*$/im.test(body) ||
      /^\s*(?:Run result|Run status)\s*:\s*(?:fail|failed|error)/im.test(body) ||
      /^\s*Failure\s*:/im.test(body)) return 'failed';
  if (/^\s*(?:Run result|Run status)\s*:\s*(?:success|passed)/im.test(body) ||
      /\b(?:Given|When|Then|And|But)\b[^\r\n]*\bsuccess\s*$/im.test(body)) return 'passed';
  return 'unknown';
}

export function rangeBounds(kind, now = Date.now(), from = '', to = '') {
  const ranges = {'24h': 86400000, '7d': 7 * 86400000, '30d': 30 * 86400000};
  if (kind === 'custom') {
    const lo = from ? new Date(from).getTime() : null, hi = to ? new Date(to).getTime() : null;
    return {from: Number.isFinite(lo) ? lo : null, to: Number.isFinite(hi) ? hi : null};
  }
  return {from: ranges[kind] ? now - ranges[kind] : null, to: null};
}

export function matchesRun(run, filters) {
  if (filters.nodeIds?.length && !filters.nodeIds.includes(run.nodePublicKey)) return false;
  if (filters.account && filters.account !== run.callerId) return false;
  if (filters.status && filters.status !== 'all' && filters.status !== run.status) return false;
  if (filters.feature) {
    const needle = filters.feature.toLowerCase();
    if (!`${run.featureCid} ${run.featureTitle}`.toLowerCase().includes(needle)) return false;
  }
  if (filters.tags?.length) {
    const existing = new Set((run.tags || []).map(t => t.toLowerCase()));
    if (!filters.tags.every(t => existing.has(t))) return false;
  }
  if ((filters.from != null || filters.to != null) && !run.createdMs) return false;
  if (filters.from != null && run.createdMs < filters.from) return false;
  if (filters.to != null && run.createdMs > filters.to) return false;
  return true;
}

export function parseTagFilter(raw) {
  return [...new Set(String(raw ?? '').split(/[\s,]+/).map(t => t.trim().toLowerCase())
    .filter(Boolean).map(t => t.startsWith('@') ? t : '@' + t))];
}

/** Resolve middleware pagination only within the configured middleware origin.
 * AEMDW may return '/mdw/v3/...' or '/v3/...' as a next link.
 */
export function middlewareUrl(base0, path0) {
  const base = new URL(String(base0).replace(/\/+$/, '') + '/');
  const path = String(path0 || '');
  const url = /^https?:\/\//i.test(path) ? new URL(path) :
    path.startsWith(base.pathname) ? new URL(path, base.origin) :
    new URL(path.replace(/^\/+/, ''), base);
  if (url.origin !== base.origin || !url.pathname.startsWith(base.pathname))
    throw new Error('Rejected untrusted middleware pagination URL');
  return url.href;
}
