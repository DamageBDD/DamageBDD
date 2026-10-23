import test from 'node:test';
import assert from 'node:assert/strict';
import { templateCards, templateFields, templateParams, templateDefaults, createPreviewGate, cadenceLabel } from '../../priv/static/js/schedule-templates.js';

const template = {id:'http-uptime', title:'HTTP uptime', category:'Availability', description:'Check uptime.', cron_spec:'*/15 * * * *', requests_per_run:1,
  fields:[{key:'target_url',label:'Target',type:'url',required:true,max_length:2048},
    {key:'expected_status',label:'Status',type:'number',required:true,default:200,min:200,max:599},
    {key:'max_ms',label:'Latency',type:'number',required:true,default:3000,min:100,max:30000}]};
const values = {target_url:'https://node.example.com/health',expected_status:'200',max_ms:'3000'};

test('explicit permission is mandatory, not truthy strings', () => {
  for (const consent of [undefined,false,0,1,'true']) assert.throws(() => templateParams(template,values,consent), /permission/);
});
test('typed parameters and no extra fields cross the request boundary', () => {
  assert.deepEqual(templateParams(template,{...values,evil:'payload'},true),{authorized:true,target_url:values.target_url,expected_status:200,max_ms:3000});
});
test('rejects userinfo, query secrets, fragments, unsafe schemes and Gherkin injection', () => {
  for (const target_url of ['http://user:secret@node.example.com/','https://node.example.com/?key=secret','https://node.example.com/#frag','file:///etc/passwd','https://node.example.com/"\nThen bad','https://{{secret}}/']) {
    assert.throws(() => templateParams(template,{...values,target_url},true));
  }
});
test('bounded integral inputs reject Infinity, NaN, negative and fractional values', () => {
  for (const max_ms of ['Infinity','NaN','0','99','30001','100.5','']) assert.throws(() => templateParams(template,{...values,max_ms},true));
});
test('only plain public strings are accepted for the content canary', () => {
  const t={fields:[{key:'contains',type:'text',label:'Text',required:true,max_length:256}]};
  assert.deepEqual(templateParams(t,{contains:'Healthy'},true),{authorized:true,contains:'Healthy'});
  assert.throws(() => templateParams(t,{contains:'{{credential}}'},true));
  assert.throws(() => templateParams(t,{contains:'x'.repeat(257)},true));
});
test('catalogue markup and attribute values are escaped', () => {
  const html=templateCards([{...template,title:'<img src=x onerror=alert(1)>',id:'"><script>bad</script>'}]);
  assert.ok(!html.includes('<img')); assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('&lt;img')); assert.ok(templateFields({...template,fields:[{...template.fields[0],placeholder:'" onfocus="bad'}]}).includes('&quot; onfocus=&quot;bad'));
});
test('starter defaults are a seven-day opt-in with UTC cadence', () => {
  const d=templateDefaults({feature:'Feature: TLS',cron_spec:'0 9 * * *',window_days:900});
  assert.equal(d.days,7); assert.equal(d.frequency,'daily-utc');
  assert.equal(templateDefaults({feature:'Feature: Ping',cron_spec:'*/15 * * * *'}).frequency,'15m');
  assert.equal(cadenceLabel('0 9 * * *'),'Daily at 09:00 UTC');
  assert.throws(()=>templateDefaults({feature:''}));
});
test('an edited in-flight preview cannot enable creation', () => {
  const gate=createPreviewGate(),spec={feature:'A',cron_spec:'0 * * * *'};
  const ticket=gate.begin(spec); gate.invalidate();
  assert.equal(gate.accept(ticket,{budget:1}),false); assert.equal(gate.current(spec),null);
});
test('only the newest request can be accepted', () => {
  const gate=createPreviewGate(), spec={feature:'A'};
  const first=gate.begin(spec), second=gate.begin(spec);
  assert.equal(gate.accept(first,{old:true}),false);
  assert.equal(gate.accept(second,{new:true}),true);
  assert.equal(gate.current(spec).preview.new,true);
});
test('accepted previews require exact spec and are immutable snapshots', () => {
  const gate=createPreviewGate(), spec={feature:'A',start_at:100,end_at:200};
  const ticket=gate.begin(spec); spec.feature='B'; gate.accept(ticket,{});
  assert.equal(gate.current(spec),null);
  assert.equal(gate.current({feature:'A',start_at:100,end_at:200}).spec.feature,'A');
  gate.invalidate(); assert.equal(gate.current({feature:'A',start_at:100,end_at:200}),null);
});
