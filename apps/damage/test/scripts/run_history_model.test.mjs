import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const source = await readFile(new URL('../../priv/static/js/run-history-model.js', import.meta.url), 'utf8');
const model = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const {
  DEFAULT_TOKEN_CONTRACT: contract, normalizeSpend, parseFeature,
  normalizeRunMeta, parseLegacyStatus, rangeBounds, matchesRun,
  parseTagFilter, middlewareUrl, aeAddress, registryRegistration,
  DEFAULT_REGISTRY_CONTRACT
} = model;
const nodeId = 'ak_' + 'A'.repeat(40), accountId = 'ak_' + 'B'.repeat(40);
const cidA = 'Qm' + 'a'.repeat(44), cidB = 'Qm' + 'b'.repeat(44);
const args = [
  {type: 'address', value: nodeId}, {type: 'int', value: '250000000'},
  {type: 'string', value: cidA}, {type: 'string', value: cidB}
];

test('normalizes a contract-filtered spend from public middleware', () => {
  const actual = normalizeSpend({
    hash: 'th_somehash', micro_time: 1781000000000000,
    payload: {tx: {function: 'spend', contract_id: contract,
      caller_id: accountId, arguments: args}}
  }, {trustedContractScope: true});
  assert.equal(actual.nodePublicKey, nodeId);
  assert.equal(actual.callerId, accountId);
  assert.equal(actual.reportCid, cidB);
  assert.equal(actual.featureCid, cidA);
  assert.equal(actual.amountRaw, '250000000');
  assert.equal(actual.createdMs, 1781000000000);
});

test('accepts a nested PayingForTx spend with the correct contract', () => {
  const result = normalizeSpend({
    hash: 'th_payfor', tx: {type: 'PayingForTx', tx: {
      tx: {contract_id: contract, function: 'spend', caller_id: accountId, arguments: args}
    }}
  });
  assert.equal(result?.nodePublicKey, nodeId);
  assert.equal(result?.callerId, accountId);
});

test('rejects unrelated contracts and transactions without immutable evidence', () => {
  assert.equal(normalizeSpend({tx: {contract_id: 'ct_other', function: 'spend', arguments: args}}), null);
  assert.equal(normalizeSpend({tx: {contract_id: contract, function: 'spend',
    arguments: [args[0], args[1], 'not-cid', cidB]}}), null);
});

test('requires on-chain contract proof or a contract-filtered source', () => {
  const raw = {payload: {tx: {arguments: args}}};
  assert.equal(normalizeSpend(raw), null);
  assert.equal(normalizeSpend(raw, {trustedContractScope: true})?.reportCid, cidB);
});

test('extracts feature title, feature/scenario tags without confusing the first @tag for a title', () => {
  const f = parseFeature('@api @smoke\nFeature: Checkout\n  Scenario: Pay\n    Given x\n  @slow @billing\n  Scenario: Refund');
  assert.equal(f.title, 'Checkout');
  assert.deepEqual(f.tags, ['@api', '@smoke', '@slow', '@billing']);
});

test('new run.meta provides status, duration, title, node/account filters', () => {
  const base = {featureTitle: '', tags: [], createdMs: null, status: 'unknown'};
  const result = normalizeRunMeta(base, {
    status: 'passed', feature_title: 'Payment flow',
    tags: ['@API', '@smoke'], start_time_hires: 1781000000.1,
    execution_time_hires: 1.2, run_id: 'run-123'
  });
  assert.equal(result.status, 'passed');
  assert.deepEqual(result.tags, ['@api', '@smoke']);
  assert.equal(result.createdMs, 1781000000100);
  assert.equal(result.duration, 1.2);
});

test('legacy run.meta result remains usable, without false successful status for unknown', () => {
  assert.equal(normalizeRunMeta({}, {result: 'success'}).status, 'passed');
  assert.equal(normalizeRunMeta({}, {result: 'assertion_failure'}).status, 'failed');
  assert.equal(normalizeRunMeta({}, {}).status, 'unknown');
  assert.equal(parseLegacyStatus('Then x line:42 fail\nFailure:\n reason'), 'failed');
  assert.equal(parseLegacyStatus('Then x line:42 success'), 'passed');
  assert.equal(parseLegacyStatus('just a random log'), 'unknown');
});

test('filters by all tags, feature, selected node, account, status and time', () => {
  const row = {
    nodePublicKey: nodeId, callerId: accountId, featureCid: cidA,
    featureTitle: 'Checkout', tags: ['@smoke', '@api'], status: 'passed', createdMs: 1781000000000
  };
  const base = {nodeIds: [nodeId], account: accountId, tags: parseTagFilter('@api smoke'),
    feature: 'check', status: 'passed', from: 1780990000000, to: 1781010000000};
  assert.equal(matchesRun(row, base), true);
  for (const overrides of [{status: 'failed'}, {nodeIds: ['ak_' + 'C'.repeat(40)]},
    {account: nodeId}, {tags: ['@none']}, {feature: 'unknown'}, {from: 1782000000000}]) {
    assert.equal(matchesRun(row, {...base, ...overrides}), false);
  }
  const seven = rangeBounds('7d', 1781000000000);
  assert.equal(seven.from, 1781000000000 - 7 * 86400000);
});

test('scopes middleware page links to origin and /mdw prefix (pagination SSRF defense)', () => {
  const base = 'https://mainnet.aeternity.io/mdw';
  assert.equal(middlewareUrl(base, '/v3/transactions?limit=20'),
    'https://mainnet.aeternity.io/mdw/v3/transactions?limit=20');
  assert.equal(middlewareUrl(base, '/mdw/v3/transactions'),
    'https://mainnet.aeternity.io/mdw/v3/transactions');
  assert.throws(() => middlewareUrl(base, 'https://evil.invalid/v3/transactions'));
  assert.throws(() => middlewareUrl(base, 'https://mainnet.aeternity.io/private/other'));
});

test('validates public identifiers without accepting URLs or injective values', () => {
  assert.equal(aeAddress(nodeId), nodeId);
  assert.equal(aeAddress('https://evil.invalid/ak_foo'), '');
  assert.equal(aeAddress('ak_" onclick="x'), '');
});


test('reads a decoded DAMAGE spend from a public transaction record', () => {
  const parsed = normalizeSpend({
    call_tx_hash: 'th_public_call', contract_id: contract,
    function: 'DamageToken.spend', caller_id: accountId,
    micro_time: 1781000000000, arguments: args
  }, {trustedContractScope: true});
  assert.equal(parsed?.reportCid, cidB);
  assert.equal(parsed?.featureCid, cidA);
  assert.equal(parsed?.callerId, accountId);
  assert.equal(parsed?.nodePublicKey, nodeId);
  assert.equal(parsed?.createdMs, 1781000000000);
  assert.equal(parsed?.txHash, 'th_public_call');
});

test('observes historical NodeRegistry register_node calls without claiming active registration', () => {
  const registration = registryRegistration({
    call_tx_hash: 'th_register', function: 'NodeRegistry.register_node',
    contract_id: DEFAULT_REGISTRY_CONTRACT,
    arguments: [{type: 'address', value: accountId}, {type: 'address', value: nodeId},
      {type: 'record', value: {}}, {type: 'record', value: {}}]
  }, {trustedRegistryScope: true});
  assert.deepEqual({...registration}, {id: nodeId, owner: accountId, name: nodeId,
    observed: true, registered: false, txHash: 'th_register'});
  assert.equal(registryRegistration({function: 'NodeRegistry.register_account',
    contract_id: DEFAULT_REGISTRY_CONTRACT,
    arguments: [{value: accountId}, {value: nodeId}, {}, {}]},
    {trustedRegistryScope: true}), null);
  assert.equal(registryRegistration({function: 'NodeRegistry.register_node',
    contract_id: 'ct_other',
    arguments: [{value: accountId}, {value: nodeId}, {}, {}]},
    {trustedRegistryScope: true}), null);
});

test('on-chain registry and token sources resolve under the middleware prefix', () => {
  assert.equal(middlewareUrl('https://mainnet.aeternity.io/mdw',
    '/v3/transactions?contract=' + contract + '&type=contract_call&type=paying_for&direction=backward&limit=50'),
    'https://mainnet.aeternity.io/mdw/v3/transactions?contract=' + contract + '&type=contract_call&type=paying_for&direction=backward&limit=50');
});

test('only likely contract transactions are hydrated from mixed node activity', () => {
  assert.equal(model.plausibleRunTransaction({type: 'ChannelCreateTxEvent', payload: {tx: {type: 'ChannelCreateTx'}}}, contract), false);
  assert.equal(model.plausibleRunTransaction({type: 'SpendTxEvent', payload: {tx: {type: 'SpendTx'}}}, contract), false);
  assert.equal(model.plausibleRunTransaction({tx: {type: 'ContractCallTx', contract_id: 'ct_different'}}), false);
  assert.equal(model.plausibleRunTransaction({tx: {type: 'ContractCallTx', contract_id: contract}}), true);
  assert.equal(model.plausibleRunTransaction({tx: {type: 'PayingForTx', tx: {tx: {type: 'ContractCallTx'}}}}), true);
  assert.equal(model.plausibleRunTransaction({tx: {contract_id: contract, arguments: args}}), true);
});

test('extracts exactly two distinct report CIDs from token calldata when arguments are unavailable', () => {
  const b64 = bin => Buffer.from(bin).toString('base64');
  const calldata = 'cb_' + b64(Buffer.concat([
    Buffer.from([23, 42, 0]), Buffer.from(cidA), Buffer.from([11, 0]), Buffer.from(cidB), Buffer.from([1, 32])
  ]));
  assert.deepEqual(model.cidsFromCallData(calldata), [cidA, cidB]);
  const parsed = normalizeSpend({hash:'th_encoded', tx: {type: 'ContractCallTx',
    contract_id: contract, caller_id: accountId, call_data: calldata}});
  assert.equal(parsed.featureCid, cidA);
  assert.equal(parsed.reportCid, cidB);
  assert.equal(parsed.callerId, accountId);
  assert.equal(parsed.nodePublicKey, '');
  assert.equal(parsed.spendEvidence, 'token_calldata');
  assert.equal(normalizeSpend({tx: {contract_id: 'ct_another', call_data: calldata}},
    {trustedContractScope:true}), null);
  assert.deepEqual(model.cidsFromCallData('cb_' + b64(cidA + cidA)), []);
  assert.deepEqual(model.cidsFromCallData('cb_' + b64(cidA + cidB + cidA)), []);
  assert.deepEqual(model.cidsFromCallData('cb_!BAD_BASE64'), []);
});

test('run.meta can label unresolved identities but never override decoded chain identities', () => {
  const encoded = {featureCid:cidA, reportCid:cidB, nodePublicKey:'', callerId:'',
    tags:[],status:'unknown'};
  const claimed = normalizeRunMeta(encoded, {node_public_key:nodeId,
    public_key:accountId, status:'passed'});
  assert.equal(claimed.nodePublicKey, nodeId);
  assert.equal(claimed.callerId, accountId);
  assert.equal(claimed.nodeSource, 'report_manifest');
  assert.equal(claimed.callerSource, 'report_manifest');
  const otherNode = 'ak_' + 'C'.repeat(40);
  const verified = normalizeRunMeta({...encoded, nodePublicKey:otherNode,
    callerId:otherNode}, {node_public_key:nodeId, public_key:accountId});
  assert.equal(verified.nodePublicKey, otherNode);
  assert.equal(verified.callerId, otherNode);
  assert.equal(verified.nodeSource, 'chain_arguments');
});
