import assert from 'node:assert/strict';
import test from 'node:test';
import {searchIndexSelectionBody, normalizeIndexCatalog} from '../priv/static/js/ecai-knowledge-search.js';
import fs from 'node:fs';

const view = fs.readFileSync(new URL('../priv/templates/ui/dashboard/ecai_console.mustache', import.meta.url), 'utf8');
const consoleJS = fs.readFileSync(new URL('../priv/static/js/ecai-console.js', import.meta.url), 'utf8');
const chatErl = fs.readFileSync(new URL('../src/ecai_chat.erl', import.meta.url), 'utf8');

test('conversation selector starts closed and mirrors Knowledge Search controls', () => {
  assert.match(view, /<details id="chatIndexes"[^>]*>/);
  assert.doesNotMatch(view.match(/<details id="chatIndexes"[^>]*>/)?.[0] || '', /\sopen(?:\s|>|=)/);
  for (const id of ['chatIndexAll','chatIndexNone','chatIndexRefresh','chatIndexChoices','chatIndexSummary']) {
    assert.match(view, new RegExp(`id="${id}"`));
  }
});

test('selected scope is passed to both persistent and guest endpoints', () => {
  assert.match(consoleJS, /body: \{message:outgoing, \.\.\.indexSelection\}/);
  assert.match(consoleJS, /message:outgoing, \.\.\.indexSelection/);
  assert.match(consoleJS, /assertChatScopedBackend\(\)/);
  assert.match(consoleJS, /chatIndexChooser\.accepts\(response\)/);
});

test('same selected-index semantics as Knowledge Search', () => {
  assert.deepEqual(searchIndexSelectionBody(null), {});
  assert.deepEqual(searchIndexSelectionBody([]), {indexes: []});
  assert.deepEqual(searchIndexSelectionBody(['wikimedia', 'shared', 'shared']),
    {indexes: ['shared','wikimedia']});
  assert.deepEqual(normalizeIndexCatalog({indexes: [
    {id: 'shared', kind: 'shared', label: 'Shared'},
    {id: 'pool:mine', kind: 'funded', scope: 'owner', label: 'Mine'}
  ]}).map(i => i.id), ['shared','pool:mine']);
});

test('scoped retrieval preserves configured LLM routing', () => {
  assert.match(chatErl, /case call_model\(Host, Port, Model, RequestSystemPrompt, Prompt\) of/);
  assert.match(chatErl, /case ecai_llm_settings:route_chat\(\) of/);
  assert.match(chatErl, /ecai_knowledge:context\(Principal, RetrievalQuery, TopK,/);
});
