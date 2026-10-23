import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {makeFeature} from '../recorder-core.mjs';

// Guard against generator ↔ Erlang step-module vocabulary drift.
const erlang = await readFile(new URL('../../../apps/damage/src/steps_browser_recorder.erl', import.meta.url), 'utf8');
test('every emitted recorded-browser command has an Erlang replay clause', () => {
  const scenario = {title:'Coverage', actions:[
    {kind:'navigation',url:'http://example.test/',cause:'manual'},
    {kind:'click',selector:'#button'},
    {kind:'fill',selector:'#name',value:'Alice'},
    {kind:'secret',selector:'#password',secretKey:'browser_secret_a8b64b21'},
    {kind:'select',selector:'#plan',value:'Pro'},
    {kind:'check',selector:'#a',checked:true},
    {kind:'check',selector:'#b',checked:false},
    {kind:'press',selector:'#search'},
    {kind:'assertText',selector:'#message',value:'Success'},
    {kind:'navigation',url:'http://example.test/success',cause:'click'},
    {kind:'navigation',url:'http://example.test/next',cause:'manual'}
  ]};
  const text = makeFeature(scenario).text;
  const verbs = [
    'I start a recorded browser at', 'I click recorded element',
    'I type into recorded field', 'I type secret', 'into recorded field',
    'I select recorded option in', 'I set recorded checkbox',
    'to checked', 'to unchecked', 'I press Enter in recorded field',
    'recorded element', 'should contain text',
    'the recorded browser URL should start with',
    'I navigate the recorded browser to', 'I close the recorded browser'
  ];
  for (const phrase of verbs) {
    assert.ok(text.includes(phrase),`generator does not emit ${phrase}`);
    assert.ok(erlang.includes(`"${phrase}"`),`Erlang replay module lacks ${phrase}`);
  }
});
