import test from 'node:test';
import assert from 'node:assert/strict';
import {makeFeature, featureFilename, actionPreview} from '../recorder-core.mjs';
const action = (kind, props = {}) => ({id:kind, enabled:true, kind, ...props});

test('generates executable vocabulary for all recorded interactions', () => {
  const session = {title:'Customer checkout', actions:[
    action('navigation', {url:'https://example.test/signup', cause:'manual'}),
    action('fill', {selector:"input[name='email']", value:'hello@example.test'}),
    action('secret', {selector:'#password', secretKey:'browser_secret_123abcde'}),
    action('select', {selector:'#plan', value:'Annual'}),
    action('check', {selector:'#tos', checked:true}),
    action('click', {selector:'#submit'}),
    action('navigation', {url:'https://example.test/account?ticket=personal', cause:'click'}),
    action('assertText', {selector:'#welcome', value:'Hello there!'}),
    action('press', {selector:'#search'})
  ]};
  const {text, warnings, steps} = makeFeature(session);
  assert.match(text, /^Feature: Customer checkout/m);
  assert.match(text, /Given I start a recorded browser at "https:\/\/example.test\/signup"/);
  assert.match(text, /When I type into recorded field "input\[name='email'\]"\n\s+"""\n\s+hello@example.test/);
  assert.match(text, /When I type secret "browser_secret_123abcde" into recorded field "#password"/);
  assert.match(text, /When I select recorded option in "#plan"/);
  assert.match(text, /When I set recorded checkbox "#tos" to checked/);
  assert.match(text, /Then the recorded browser URL should start with "https:\/\/example.test\/account"/);
  assert.match(text, /Then recorded element "#welcome" should contain text/);
  assert.match(text, /Then I close the recorded browser\n$/);
  assert.equal(text.includes('personal'), false); // navigation assertion cannot leak query values
  assert.equal(steps, 10);
  assert.equal(warnings.length, 2);
});
test('skips excluded steps and handles newlines as Gherkin docstrings', () => {
  const session = {title:'Multiline\nfeature', actions:[action('navigation',{url:'http://localhost:8000/'}),action('fill',{selector:'#notes',value:'line 1\nline 2'}), action('click',{selector:'#bad',enabled:false})]};
  const {text} = makeFeature(session);
  assert.match(text, /^Feature: Multiline feature/);
  assert.match(text, /      line 1\n      line 2/);
  assert.ok(!text.includes('#bad'));
});
test('handles punctuation without corrupting step tokenizer', () => {
  const session = {title:'Quotes', actions:[action('navigation',{url:'http://localhost:8000/?q=%22hello%22'}),action('fill',{selector:'#x',value:'She said "yes"'})]};
  const result = makeFeature(session);
  assert.match(result.text,/She said "yes"/);
  assert.equal(featureFilename('Checkout <test>/now'), 'checkout-test-now.feature');
  assert.match(actionPreview(action('click',{label:'Pay'})),/Pay/);
});
test('rejects unsafe step arguments rather than exporting broken Gherkin', () => {
  assert.throws(() => makeFeature({actions:[action('navigation',{url:'https://example.test'}),action('click',{selector:'[a="unsafe"]'})]}), /double quotes/);
  assert.throws(() => makeFeature({actions:[action('navigation',{url:'https://example.test'}),action('fill',{selector:'#x',value:'"""'})]}), /delimiter/);
  assert.throws(() => makeFeature({actions:[action('navigation',{url:'javascript:alert(1)'})]}), /HTTP and HTTPS/);
});


test('refuses reordered actions before the browser has started', () => {
  assert.throws(() => makeFeature({actions:[
    action('click', {selector:'#submit'}),
    action('navigation', {url:'https://example.test/'})
  ]}), /first enabled step/);
});

test('refuses disabling the starting page when actions would precede navigation', () => {
  assert.throws(() => makeFeature({actions:[
    action('navigation', {url:'https://example.test/', enabled:false}),
    action('fill', {selector:'#name', value:'Alice'}),
    action('navigation', {url:'https://example.test/done'})
  ]}), /first enabled step/);
});

test('exports account-scoped secret names without a plaintext fallback', () => {
  const {text, warnings} = makeFeature({actions:[
    action('navigation', {url:'https://example.test/'}),
    action('secret', {selector:'#password', secretKey:'browser_secret_a1', value:'DO_NOT_EXPORT'})
  ]});
  assert.match(text, /Set account secret: browser_secret_a1/);
  assert.match(warnings.join(' '), /account-scoped/);
  assert.ok(!text.includes('DO_NOT_EXPORT'));
  assert.ok(!text.includes('Set node secret'));
});

test('rejects missing selectors and unknown enabled actions', () => {
  const start = action('navigation', {url:'https://example.test/'});
  assert.throws(() => makeFeature({actions:[start,action('click', {selector:''})]}), /cannot be empty/);
  assert.throws(() => makeFeature({actions:[start,action('notImplemented')]}), /unsupported action/);
  assert.doesNotThrow(() => makeFeature({actions:[start,action('notImplemented', {enabled:false})]}));
});

test('normalises Windows text lines and preserves empty fill values', () => {
  const {text} = makeFeature({actions:[
    action('navigation', {url:'https://example.test/'}),
    action('fill', {selector:'#notes', value:'first\r\nsecond'}),
    action('fill', {selector:'#empty', value:''})
  ]});
  assert.ok(!text.includes('\r'));
  assert.match(text, /first\n      second/);
  assert.match(text, /field "#empty"\n      """\n      \n      """/);
});

test('rejects control characters in CSS parameters and docstrings', () => {
  const start = action('navigation', {url:'https://example.test/'});
  assert.throws(() => makeFeature({actions:[start,action('click', {selector:'#a\u0000b'})]}));
  assert.throws(() => makeFeature({actions:[start,action('fill', {selector:'#a',value:'x\u0000y'})]}), /control characters/);
});
