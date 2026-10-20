'use strict';
// Dependency-free browser contract test: run with Node 20+.
// Exercises the actual dashboard controller against a DOM/API stand-in.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'priv/templates/ui/dashboard/compute_settings.mustache'), 'utf8');
const script = fs.readFileSync(path.join(root, 'priv/static/js/ecai-compute-settings.js'), 'utf8');
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));

class Element {
  constructor(id = '') {
    this.id = id;
    this.dataset = {};
    this.listeners = new Map();
    this.attributes = {};
    this.children = [];
    this.value = '';
    this.checked = false;
    this.textContent = '';
    this.disabled = false;
    this.hidden = false;
    this.open = false;
    this.style = {};
    this.type = '';
    this.href = '';
    this.formFields = new Map();
    this.elements = {namedItem: (name) => this.formFields.get(name) || null};
  }
  addEventListener(type, cb) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(cb);
    this.listeners.set(type, listeners);
  }
  fire(type) {
    for (const listener of this.listeners.get(type) || []) {
      listener({preventDefault() {}, currentTarget: this, target: this});
    }
  }
  setAttribute(key, value) { this.attributes[key] = value; }
  getAttribute(key) { return this.attributes[key]; }
  replaceChildren(...elements) { this.children = [...elements]; }
  append(...elements) { this.children.push(...elements); }
  remove() {}
  scrollIntoView() {}
  select() {}
  querySelector(selector) { return selector === '[type="submit"]' ? this.submitButton : null; }
  reset() { for (const input of this.formFields.values()) { input.value = ''; input.checked = false; } }
}
const elements = new Map([...ids].map((id) => [id, new Element(id)]));
const $ = (id) => {
  assert.ok(ids.has(id), `Missing DOM element #${id}`);
  return elements.get(id);
};
for (const [form, names] of Object.entries({
  computeAwsForm: ['role_arn', 'region', 'job_queue', 'job_definition', 'bucket'],
  computeGcpForm: ['project_id', 'region', 'job', 'bucket', 'service_account'],
  computePolicyForm: ['enabled', 'monthly', 'per_job', 'mint_monthly'],
  computeMintPolicyForm: ['enabled', 'recipient'],
  computeJobForm: ['source_job_id', 'provider', 'vcpus', 'memory_mb', 'max_seconds', 'max_attempts'],
  computeMintForm: ['job_id', 'fee']
})) {
  $(form).submitButton = new Element(`${form}-save`);
  for (const name of names) $(form).formFields.set(name, new Element(`${form}-${name}`));
}
$('computeChooseAws').dataset.computeProviderChoice = 'aws_batch';
$('computeChooseGcp').dataset.computeProviderChoice = 'cloud_run';
const dom = {
  getElementById: (id) => $(id),
  createElement: (name) => new Element(name),
  querySelectorAll: (query) => query === '[data-compute-provider-choice]' ?
    [$('computeChooseAws'), $('computeChooseGcp')] : [],
  body: new Element('body'),
  execCommand: () => true
};
const clipboard = [];
const sandbox = {
  window: {confirm: () => true}, document: dom,
  crypto: webcrypto,
  navigator: {clipboard: {writeText: async (value) => clipboard.push(value)}},
  FormData: class {
    constructor(form) { this.form = form; }
    *entries() { for (const [key, input] of this.form.formFields) yield [key, input.value]; }
  }
};
vm.runInNewContext(script, sandbox, {filename: 'ecai-compute-settings.js'});
const externalId = 'a'.repeat(48);
const settings = {
  providers: {}, provider_setup: {}, connection_hints: {},
  budget: {monthly_cents: 0, per_job_cents: 0, mint_monthly_cents: 0, remote_enabled: false},
  mint: {enabled: false, recipient: ''}, reservations: [], mint_requests: []
};
const calls = [];
const request = async (route, options = {}) => {
  calls.push({route, ...options});
  if (route === '/ecai/compute/settings') return {ok: true, data: settings};
  if (route === '/ecai/compute/mintable' || route === '/ecai/compute/eligible-sources')
    return {ok: true, data: []};
  if (route === '/ecai/compute/providers/aws_batch/prepare') {
    settings.provider_setup.aws_batch_external_id = externalId;
    return {ok: true, data: {external_id: externalId}};
  }
  if (route === '/ecai/compute/providers/aws_batch' && options.method === 'POST') {
    settings.providers.aws_batch = {...options.body, status: 'unverified', external_id: externalId};
    return {ok: true, data: settings.providers.aws_batch};
  }
  if (route === '/ecai/compute/providers/aws_batch/verify') {
    settings.providers.aws_batch.status = 'identity_verified';
    return {ok: true, data: settings.providers.aws_batch};
  }
  throw new Error(`Unexpected request ${route}`);
};
const wait = async () => {
  // Event handlers intentionally fire-and-forget in the dashboard controller.
  for (let i = 0; i < 3; i++) await new Promise((resolve) => setImmediate(resolve));
};
(async () => {
  sandbox.window.EcaiComputeSettings.init({request, toast() {}, openLogin() {}, currentToken: () => 'valid-demo-token'});
  assert.equal($('computeAwsPanel').hidden, false);
  assert.equal($('computeGcpPanel').hidden, true);
  assert.equal($('computeChooseAws').getAttribute('aria-pressed'), 'true');
  await sandbox.window.EcaiComputeSettings.refresh();
  assert.equal($('computeCopyExternalId').disabled, true);
  $('computePrepareAws').fire('click');
  await wait();
  assert.equal($('computeAwsExternalId').textContent, externalId);
  assert.equal($('computeCopyExternalId').disabled, false);
  assert.equal($('computeCopyTrustPolicy').disabled, true); // not safe without role ARN
  assert.equal(calls.find((c) => c.route.endsWith('/prepare')).method, 'POST');
  settings.connection_hints.aws_coordinator_role_arn = 'arn:aws:iam::210987654321:role/EcaiCoordinator';
  await sandbox.window.EcaiComputeSettings.refresh();
  assert.equal($('computeCopyTrustPolicy').disabled, false);
  $('computeCopyTrustPolicy').fire('click');
  await wait();
  const trust = JSON.parse(clipboard.at(-1));
  assert.equal(trust.Statement[0].Principal.AWS, settings.connection_hints.aws_coordinator_role_arn);
  assert.equal(trust.Statement[0].Condition.StringEquals['sts:ExternalId'], externalId);
  assert.notEqual(trust.Statement[0].Principal.AWS, '*');
  settings.connection_hints.aws_coordinator_role_arn = '*';
  await sandbox.window.EcaiComputeSettings.refresh();
  assert.equal($('computeCopyTrustPolicy').disabled, true);
  $('computeChooseGcp').fire('click');
  assert.equal($('computeAwsPanel').hidden, true);
  assert.equal($('computeGcpPanel').hidden, false);
  assert.equal($('computeChooseGcp').getAttribute('aria-pressed'), 'true');
  const project = $('computeGcpForm').elements.namedItem('project_id');
  project.value = 'ecai-demo-123';
  project.fire('input');
  assert.equal($('computeGcpConsoleLink').href,
    'https://console.cloud.google.com/run/jobs?project=ecai-demo-123');
  assert.equal($('computeGcpWifLink').href,
    'https://console.cloud.google.com/iam-admin/workload-identity-pools?project=ecai-demo-123');
  project.value = 'https://attacker.example/?project=evil';
  project.fire('input');
  assert.equal($('computeGcpConsoleLink').href, 'https://console.cloud.google.com/run/jobs');
  $('computeChooseAws').fire('click');
  for (const [key, value] of Object.entries({role_arn: 'arn:aws:iam::123456789012:role/EcaiIndexer',
    region: 'ap-southeast-2', job_queue: 'ecai-index-spot', job_definition: 'ecai-index-job',
    bucket: 'ecai-index-artifacts'})) $('computeAwsForm').elements.namedItem(key).value = value;
  $('computeAwsForm').elements.namedItem('region').fire('input');
  assert.equal($('computeAwsBatchLink').href, 'https://console.aws.amazon.com/batch/home?region=ap-southeast-2');
  $('computeAwsForm').fire('submit');
  await wait();
  assert.equal($('computeVerifyAws').disabled, false);
  assert.equal($('computeNextBudget').disabled, true);
  $('computeVerifyAws').fire('click');
  await wait();
  assert.equal($('computeNextBudget').disabled, false);
  assert.equal($('computeAwsStatus').textContent, 'Identity verified');
  console.log('ECAI provider onboarding smoke test: PASS');
})().catch((error) => { console.error(error); process.exitCode = 1; });
