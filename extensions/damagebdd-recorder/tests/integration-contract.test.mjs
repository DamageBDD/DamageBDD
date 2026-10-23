// Source-contract checks, not a substitute for Erlang EUnit or live replay.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source = path => readFile(new URL('../../../apps/damage/src/' + path, import.meta.url), 'utf8');
const [recorder, native, client, runner] = await Promise.all([
  source('steps_browser_recorder.erl'), source('steps_webdriver.erl'),
  source('damage_webdriver.erl'), source('damage.erl')
]);
test('recorder delegates to the existing role-guarded session lifecycle', () => {
  assert.match(recorder, /-damage_roles\(\[node_admin\]\)\./);
  assert.match(native, /-damage_roles\(\[node_admin\]\)\./);
  assert.match(recorder, /steps_utils:is_admin\(Context\)/);
  assert.match(recorder, /steps_webdriver:step\(/);
  assert.ok(!recorder.includes('browser_recorder_session'));
  assert.ok(!recorder.includes('damage_gun:request'));
  assert.match(runner, /steps_webdriver:cleanup\(Final\)/);
  assert.match(runner, /steps_webdriver:cleanup_owner\(\)/);
});
test('recorder secret lookup uses an authenticated account scope only', () => {
  assert.match(native, /maps:get\(public_key, Context, undefined\), Name, Css/);
  assert.match(client, /secrets:retrieve_decrypt\(\{account, Owner\}, Name\)/);
  assert.ok(!recorder.includes('secrets:retrieve_decrypt'));
  const secretHelper = client.slice(client.indexOf('account_secret(Owner, Name) when'), client.indexOf('select_option(Css, Wanted, S) ->'));
  assert.ok(!secretHelper.includes('binary_to_existing_atom'));
  assert.ok(!secretHelper.includes('retrieve_decrypt(Name)'));
});
test('integration preserves dynamic discovery rather than forcing the recorder ahead of roles', () => {
  assert.match(runner, /Module <- damage_utils:loaded_steps\(\)/);
  assert.match(runner, /steps_utils:step_module_allowed\(Module, Context\)/);
  assert.ok(!runner.includes('["steps_browser_recorder" |'));
});
