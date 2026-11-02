import assert from 'node:assert/strict';
import test from 'node:test';
import {resultTitle, resultExcerpt} from '../priv/static/js/ecai-knowledge-search.js';

test('human record title precedes preview and document ID', () => {
  assert.equal(resultTitle({record:{title:'  Quantum\nmechanics '}, preview:'Opaque preview',doc_id:'abc'}),'Quantum mechanics');
  assert.equal(resultTitle({doc_id:'a'.repeat(500)}),'Knowledge record');
});
test('malicious text stays text; no unsafe HTML is produced', () => {
  assert.equal(resultTitle({record:{title:'<img src=x onerror=alert(1)>'}}),'<img src=x onerror=alert(1)>');
});
test('machine identifiers are omitted only from the excerpt', () => {
  const value = {record:{text:'Testing the echo server. Account ak_'+'a'.repeat(50)+' transaction th_'+'b'.repeat(50)}};
  const before=structuredClone(value);
  assert.ok(resultExcerpt(value,'echo').identifiersHidden);
  assert.ok(!resultExcerpt(value,'echo').snippet.includes('ak_'));
  assert.deepEqual(value,before);
});
test('query context remains visible in a long document', () => {
  const result={record:{text:'intro '.repeat(150)+'orbital orchard is ready. '+ 'trailing '.repeat(80)}};
  const {snippet}=resultExcerpt(result,'orbital orchard');
  assert.ok(snippet.includes('orbital orchard'));
  assert.ok(snippet.length<=362);
});
test('absent records and non-string snippets do not throw', () => {
  assert.equal(resultExcerpt(null).snippet,'');
  assert.equal(resultTitle(undefined),'Knowledge record');
  assert.ok(resultTitle({record:{title:'x'.repeat(1000)}}).length<=180);
});
