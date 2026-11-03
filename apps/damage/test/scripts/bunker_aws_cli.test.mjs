import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {awsAdminCommands, shellQuote} from '../../priv/static/js/node-bunker.js';

const BASELINE = '10000000-0000-4000-8000-000000000001';
const TESTED = '20000000-0000-4000-8000-000000000002';
const OTHER = '30000000-0000-4000-8000-000000000003';
const ACCOUNT = '123456789012';
const ARN = `arn:aws:secretsmanager:ap-southeast-2:${ACCOUNT}:secret:/test/bunker-AbCdEf`;
const NOW = Math.floor(Date.now() / 1000);
const SECRET = 'test-only secret "quotes" \' $(not-executed) \\ backslash\ntrailing newline\n';
const fixture = () => ({busy:false, last_error:null, health:{status:'passed', completed_at:NOW - 1, target:'target-hash', fingerprint:'fingerprint-hash',
  setup:{aws:{region:'ap-southeast-2', expected_account_id:ACCOUNT, expected_role_name:'bunker-runtime', secret_id:'/test/bunker'}}},
  evidence:{pending:{status:'passed', completed_at:NOW - 10, target:'target-hash', fingerprint:'fingerprint-hash',
    recovery:{secret_provenance:{baseline_version_id:BASELINE, version_id:TESTED}}}}});

// A strictly local AWS CLI substitute. Locking models independent commands in
// a shell pipeline without losing concurrent log/state writes. Secrets are
// deliberately fake; no environment credentials or network operations are used.
const MOCK_AWS = String.raw`#!/usr/bin/env python3
import fcntl, json, os, sys
from pathlib import Path
root = Path(os.environ['BUNKER_MOCK_DIR'])
args = sys.argv[1:]
original = list(args)
for option in ('--profile', '--region'):
    if option in args:
        at = args.index(option)
        del args[at:at+2]
for option in ('--no-cli-pager', '--no-cli-auto-prompt'):
    if option in args:
        args.remove(option)
service, action = args[:2]
def opt(name, fallback=None):
    return args[args.index(name)+1] if name in args else fallback
# Read stdin before holding the lock: the producer may also need it.
request = None
if (service, action) == ('secretsmanager', 'put-secret-value'):
    try:
        request = json.load(sys.stdin)
    except Exception:
        request = None
with (root/'lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.loads((root/'state.json').read_text())
    state['calls'].append(original)
    mode = state.get('mode', '')
    status, output = 0, None
    versions = state['versions']
    baseline, other = state['baseline'], state['other']
    def move(stage, target, remove=None):
        holders = [key for key, labels in versions.items() if stage in labels]
        if holders and (remove is None or holders != [remove]):
            return False
        if remove and remove not in holders:
            return False
        if target and target not in versions:
            return False
        for key in holders:
            versions[key].remove(stage)
        if target:
            versions[target].append(stage)
        return True
    if (service, action) == ('sts', 'get-caller-identity'):
        account = '999999999999' if mode == 'wrong-account' else state['account']
        output = account if opt('--query') == 'Account' else {'Account':account, 'Arn':'test-admin'}
    elif (service, action) == ('configure', 'set'):
        if args[2:] != ['cli_history', 'disabled']:
            status = 2
        else:
            state['history_disabled'] = True
    elif (service, action) == ('secretsmanager', 'describe-secret'):
        state['describes'] = state.get('describes', 0) + 1
        output = {'ARN':state['arn'], 'RotationEnabled':mode == 'rotation', 'VersionIdsToStages':versions}
    elif (service, action) == ('secretsmanager', 'get-secret-value'):
        state['get_calls'] = state.get('get_calls', 0) + 1
        if mode == 'current-before-get':
            versions[baseline].remove('AWSCURRENT')
            versions[other] = ['AWSCURRENT']
        version, stage = opt('--version-id'), opt('--version-stage')
        if mode == 'get-fails' or not state.get('history_disabled') or stage not in versions.get(version, []):
            status = 3
        else:
            output = {'VersionId':version, 'VersionStages':versions[version], 'SecretString':state['secret']}
            if mode == 'empty-secret':
                output['SecretString'] = ''
            if mode == 'binary-secret':
                del output['SecretString']
                output['SecretBinary'] = 'eA=='
    elif (service, action) == ('secretsmanager', 'put-secret-value'):
        if mode == 'put-fails' or request is None:
            status = 4
        elif not state.get('history_disabled') or request.get('SecretId') != state['arn']:
            status = 5
        else:
            token = request['ClientRequestToken']
            versions[token] = request['VersionStages']
            state['created'] = token
            # Save only fake test input for exact-byte assertions.
            (root/'captured-request.json').write_text(json.dumps(request))
            output = {'VersionId':token, 'Stages':versions[token]}
            if mode == 'current-after-put':
                versions[baseline].remove('AWSCURRENT')
                versions[other] = ['AWSCURRENT']
    elif (service, action) == ('secretsmanager', 'update-secret-version-stage'):
        stage = opt('--version-stage')
        target, remove = opt('--move-to-version-id'), opt('--remove-from-version-id')
        if stage == 'AWSPENDING' and mode == 'pending-race':
            versions[other] = ['AWSPENDING']
        if stage == 'AWSCURRENT' and mode == 'promotion-current-race':
            versions[baseline].remove('AWSCURRENT')
            versions[other] = ['AWSCURRENT']
        if not move(stage, target, remove):
            status = 6
        else:
            output = {'ARN':state['arn']}
    elif (service, action) == ('secretsmanager', 'list-secret-version-ids'):
        output = {'Versions':[{'VersionId':key,'VersionStages':labels} for key,labels in versions.items()]}
    elif service == 'iam' or (service, action) == ('secretsmanager', 'get-resource-policy'):
        output = {}
    else:
        status = 99
    (root/'state.json').write_text(json.dumps(state))
    if output is not None:
        print(output if isinstance(output, str) else json.dumps(output))
    if status:
        print('Simulated AWS failure', file=sys.stderr)
    sys.exit(status)
`;

async function execute(command, {mode = '', promotion = false, versions, arn = ARN} = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'bunker-aws-cli-'));
  try {
    const initial = {mode, account:ACCOUNT, arn, baseline:BASELINE, other:OTHER, secret:SECRET, calls:[],
      versions:versions || {[BASELINE]:['AWSCURRENT'], ...(promotion ? {[TESTED]:['AWSPENDING']} : {})}};
    if (mode === 'existing-pending') initial.versions[OTHER] = ['AWSPENDING'];
    await writeFile(join(directory, 'state.json'), JSON.stringify(initial));
    await writeFile(join(directory, 'aws'), MOCK_AWS, {mode:0o700});
    const result = spawnSync('bash', ['--noprofile', '--norc', '-c', command], {encoding:'utf8', timeout:15000,
      env:{PATH:`${directory}:${process.env.PATH}`, BUNKER_MOCK_DIR:directory, BUNKER_ADMIN_PROFILE:'test-admin'}});
    assert.equal(result.error, undefined, result.error?.message);
    const state = JSON.parse(await readFile(join(directory, 'state.json'), 'utf8'));
    let request = null;
    try { request = JSON.parse(await readFile(join(directory, 'captured-request.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    assert.ok(!(result.stdout + result.stderr + JSON.stringify(state.calls)).includes(SECRET), 'Secret must stay out of argv and terminal output');
    return {...result, state, request};
  } finally { await rm(directory, {recursive:true, force:true}); }
}
const operation = (call, name) => call.includes('secretsmanager') && call.includes(name);
const writes = state => state.calls.filter(call => operation(call,'put-secret-value') || operation(call,'update-secret-version-stage'));

// Require syntax validity independently of fake-AWS behavior.
test('admin blocks are valid Bash and shell quoting preserves literal adversarial text', () => {
  const commands = awsAdminCommands(fixture(), NOW);
  for (const name of ['inspect','pending','promote']) {
    assert.ok(commands[name]);
    const result = spawnSync('bash', ['-n'], {input:commands[name], encoding:'utf8'});
    assert.equal(result.status, 0, `${name}: ${result.stderr}`);
  }
  const text = "quote' dollars $(printf wrong) `printf wrong`\nsecond line";
  const quoted = spawnSync('bash', ['--noprofile','--norc','-c', `printf '%s' ${shellQuote(text)}`], {encoding:'utf8'});
  assert.equal(quoted.status, 0);
  assert.equal(quoted.stdout, text);
  const invalid = fixture(); invalid.health.setup.aws.secret_id = '/test/$(touch wrong)';
  assert.equal(awsAdminCommands(invalid, NOW).pending, '');
});

test('promotion template requires fresh passing evidence bound to this deployment and distinct valid IDs', () => {
  const reject = mutate => { const data = fixture(); mutate(data); assert.equal(awsAdminCommands(data, NOW).promote, ''); };
  reject(data => { data.evidence = {}; });
  reject(data => { data.health.status = 'failed'; });
  reject(data => { data.health.completed_at = NOW - 61; });
  reject(data => { data.health.completed_at = NOW + 1; });
  reject(data => { data.evidence.pending.status = 'failed'; });
  reject(data => { data.evidence.pending.completed_at = NOW - 86401; });
  reject(data => { data.evidence.pending.completed_at = NOW + 1; });
  reject(data => { data.evidence.pending.target = 'different'; });
  reject(data => { data.health.fingerprint = 'different'; });
  reject(data => { data.evidence.pending.recovery.secret_provenance.version_id = BASELINE; });
  reject(data => { data.evidence.pending.recovery.secret_provenance.version_id = "';exit 0;#"; });
  reject(data => { data.busy = true; });
  reject(data => { data.last_error = 'storage unavailable'; });
});

test('inspection reads identity, versions and policy references without secret retrieval or AWS writes', async () => {
  const result = await execute(awsAdminCommands(fixture(), NOW).inspect);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(writes(result.state).length, 0);
  assert.equal(result.state.get_calls || 0, 0);
  assert.ok(result.state.calls.some(call => call.includes('get-role')));
});

test('prepare preserves the exact current SecretString via stdin and only conditionally attaches AWSPENDING', async () => {
  const result = await execute(awsAdminCommands(fixture(), NOW).pending);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.request.SecretString, SECRET);
  assert.equal(result.request.SecretId, ARN);
  assert.match(result.request.ClientRequestToken, /^[0-9a-f-]{36}$/);
  assert.deepEqual(result.request.VersionStages, [`HANDOFF-${result.state.created}`]);
  assert.deepEqual(result.state.versions[BASELINE], ['AWSCURRENT']);
  assert.deepEqual(result.state.versions[result.state.created], ['AWSPENDING']);
  const attach = result.state.calls.find(call => operation(call,'update-secret-version-stage') && call.includes('AWSPENDING'));
  assert.ok(attach);
  assert.ok(!attach.includes('--remove-from-version-id'), 'A competing AWSPENDING holder must not be displaced');
  const put = result.state.calls.find(call => operation(call,'put-secret-value'));
  assert.equal(put[put.indexOf('--cli-input-json') + 1], 'file:///dev/stdin');
  assert.ok(result.state.calls.findIndex(call => call.includes('cli_history')) < result.state.calls.findIndex(call => operation(call,'get-secret-value')));
  assert.match(result.stdout, /Next: run Check pending version/);
});

test('prepare stops before retrieval/writes for wrong account, mismatched ARN, rotation or existing pending', async () => {
  const command = awsAdminCommands(fixture(), NOW).pending;
  for (const options of [{mode:'wrong-account'}, {mode:'rotation'}, {mode:'existing-pending'},
    {arn:ARN.replace(ACCOUNT, '999999999999')}, {arn:ARN.replace('ap-southeast-2', 'eu-west-1')}]) {
    const result = await execute(command, options);
    assert.notEqual(result.status, 0, JSON.stringify(options));
    assert.equal(writes(result.state).length, 0, JSON.stringify(options));
    assert.equal(result.state.get_calls || 0, 0, JSON.stringify(options));
  }
});

test('prepare does not attach pending or change current after retrieval, value-validation or creation failure', async () => {
  for (const mode of ['get-fails', 'empty-secret', 'binary-secret', 'put-fails', 'current-before-get']) {
    const result = await execute(awsAdminCommands(fixture(), NOW).pending, {mode});
    assert.notEqual(result.status, 0, mode);
    assert.equal(result.state.created, undefined, mode);
    assert.equal(result.state.calls.filter(call => operation(call,'update-secret-version-stage')).length, 0, mode);
    assert.ok(!result.stdout.includes('Next: run Check pending version'), mode);
  }
});

test('prepare detects concurrent pending/current changes and never steals an existing pending label', async () => {
  const command = awsAdminCommands(fixture(), NOW).pending;
  const pending = await execute(command, {mode:'pending-race'});
  assert.notEqual(pending.status, 0);
  assert.deepEqual(pending.state.versions[OTHER], ['AWSPENDING']);
  assert.deepEqual(pending.state.versions[pending.state.created], [`HANDOFF-${pending.state.created}`]);
  assert.deepEqual(pending.state.versions[BASELINE], ['AWSCURRENT']);
  const current = await execute(command, {mode:'current-after-put'});
  assert.notEqual(current.status, 0);
  assert.deepEqual(current.state.versions[OTHER], ['AWSCURRENT']);
  assert.ok(!current.stdout.includes('Next: run Check pending version'));
});

test('promotion moves AWSCURRENT using exact tested and baseline IDs, never retrieving the secret', async () => {
  const result = await execute(awsAdminCommands(fixture(), NOW).promote, {promotion:true});
  assert.equal(result.status, 0, result.stderr);
  const write = writes(result.state);
  assert.equal(write.length, 1);
  assert.equal(write[0][write[0].indexOf('--move-to-version-id') + 1], TESTED);
  assert.equal(write[0][write[0].indexOf('--remove-from-version-id') + 1], BASELINE);
  assert.ok(result.state.versions[TESTED].includes('AWSCURRENT'));
  assert.equal(result.state.get_calls || 0, 0);
  assert.match(result.stdout, /Verify current version & restore, then Restart & verify/);
});

test('promotion refuses changed current/pending labels and a concurrent current-version replacement', async () => {
  const command = awsAdminCommands(fixture(), NOW).promote;
  for (const versions of [
    {[BASELINE]:[],[TESTED]:['AWSPENDING'],[OTHER]:['AWSCURRENT']},
    {[BASELINE]:['AWSCURRENT'],[TESTED]:[],[OTHER]:['AWSPENDING']}
  ]) {
    const result = await execute(command, {promotion:true, versions});
    assert.notEqual(result.status, 0);
    assert.equal(writes(result.state).length, 0);
  }
  const race = await execute(command, {promotion:true, mode:'promotion-current-race'});
  assert.notEqual(race.status, 0);
  assert.deepEqual(race.state.versions[OTHER], ['AWSCURRENT']);
  assert.ok(!race.state.versions[TESTED].includes('AWSCURRENT'));
});

// A block can be copied while valid and executed after the rehearsal expires.
test('copied promotion commands refuse expired or future rehearsal timestamps before calling AWS', async () => {
  for (const generatedAt of [NOW - 86410, NOW + 600]) {
    const data = fixture();
    data.health.completed_at = generatedAt - 1;
    data.evidence.pending.completed_at = generatedAt - 10;
    const command = awsAdminCommands(data, generatedAt).promote;
    assert.ok(command, 'The command was eligible when generated');
    const result = await execute(command, {promotion:true});
    assert.notEqual(result.status, 0);
    assert.equal(result.state.calls.length, 0, 'Expired/future evidence must stop before any AWS call');
    assert.deepEqual(result.state.versions[BASELINE], ['AWSCURRENT']);
    assert.deepEqual(result.state.versions[TESTED], ['AWSPENDING']);
  }
});
