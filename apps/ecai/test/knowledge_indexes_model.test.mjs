import assert from 'node:assert/strict';
import test from 'node:test';
import {searchIndexSelectionBody, normalizeIndexCatalog} from '../priv/static/js/ecai-knowledge-search.js';

test('all omits the filter but none sends an empty array', () => {
  assert.deepEqual(searchIndexSelectionBody(null), {});
  assert.deepEqual(searchIndexSelectionBody([]), {indexes: []});
});
test('explicit selection has canonical order and no duplicates', () => {
  const ids = ['wikimedia', 'shared', 'shared'];
  assert.deepEqual(searchIndexSelectionBody(ids), {indexes: ['shared','wikimedia']});
  assert.deepEqual(ids, ['wikimedia','shared','shared']);
});
test('invalid, non-UTF8-sized and excessive selectors are rejected', () => {
  for (const input of [undefined, 'shared', {}, [null], [''], [5], ['é'.repeat(65)], Array(129).fill('shared')])
    assert.throws(() => searchIndexSelectionBody(input));
});
test('catalog uses a presentation whitelist rather than retaining private paths', () => {
  const [row] = normalizeIndexCatalog({indexes:[{id:'pool:mine',kind:'funded',scope:'owner',state:'ready',
    path:'/secrets/manifest',manifest:{private:'x'},label:' My index\n ',description:'Test'}]});
  assert.equal(row.label, 'My index');
  assert.equal(row.scope, 'owner');
  assert.equal(row.path, undefined);
  assert.equal(row.manifest, undefined);
});
test('malicious catalog labels stay plain strings for textContent rendering', () => {
  const [row] = normalizeIndexCatalog({indexes:[{id:'shared',label:'<img src=x onerror=alert(1)>',state:'invalid'}]});
  assert.equal(row.label, '<img src=x onerror=alert(1)>');
  assert.equal(row.state, 'unknown');
});
test('bad or ambiguous catalogs fail rather than broadening a selection', () => {
  for (const data of [{}, {indexes:'all'}, {indexes:[{}]}, {indexes:[{id:'shared'},{id:'shared'}]}, {indexes:Array(1025).fill({id:'x'})}])
    assert.throws(() => normalizeIndexCatalog(data));
});
