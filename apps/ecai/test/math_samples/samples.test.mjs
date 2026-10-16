import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {MATH_SAMPLES} from '../../priv/static/js/ecai-math-samples.js';
import {curveInvariants,parseQ,formatQ,tracePoint,scalarPoint,sageScript} from '../../priv/static/js/ecai-math-exact.js';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const byId=id=>MATH_SAMPLES.samples.find(s=>s.id===id);
test('13 curated examples, 12 positives, one rejection',()=>{
  assert.equal(MATH_SAMPLES.samples.length,13);assert.equal(MATH_SAMPLES.samples.filter(s=>s.expected==='accept').length,12);
  assert.equal(new Set(MATH_SAMPLES.samples.map(s=>s.id)).size,13);assert.equal(MATH_SAMPLES.default_id,'doubling-6');
});
for(const sample of MATH_SAMPLES.samples) {
  test(`${sample.id}: bytes, digest and native shape`,async()=>{
    const text=await readFile(new URL(`../../priv/static/math-samples/${sample.file}`,import.meta.url),'utf8');
    assert.equal(text,sample.path_json);assert.equal(createHash('sha256').update(text).digest('hex'),sample.path_sha256);
    assert.deepEqual(JSON.parse(text),sample.path);assert.equal(sample.path.verification,undefined);
    assert.equal(sample.path.id.length,64);assert.equal(sample.map_ids.length,sample.path.hops);
    assert.equal(sample.model_ids.length,sample.path.hops+1);
  });
  test(`${sample.id}: exact local point experiment`,()=>{
    for(const pt of sample.points) {
      if(sample.expected==='reject')assert.throws(()=>tracePoint(sample.path,pt.x,pt.y),/not on the target/);
      else assert.equal(tracePoint(sample.path,pt.x,pt.y).length,sample.path.hops+1);
    }
  });
  test(`${sample.id}: exact nonsingular model invariants`,()=>{
    for(const c of [sample.path.source,...sample.path.steps.map(s=>s.map.codomain)])assert.notEqual(curveInvariants(c).discriminant,'0');
  });
}
test('doubling fixture agrees with independent group-law computation',()=>{
  const p=byId('doubling-6').path;const a=tracePoint(p,'12','36').at(-1),b=scalarPoint(p.source,'12','36',2);
  assert.deepEqual(a,b);assert.equal(a.x,'25/4');assert.equal(a.y,'-35/8');
});
test('tripling fixture agrees with independent group-law computation',()=>{
  const p=byId('tripling-j0').path;assert.deepEqual(tracePoint(p,'2','3').at(-1),scalarPoint(p.source,'2','3',3));
});
test('Legendre source j is exact and nonintegral',()=>assert.equal(curveInvariants(byId('legendre-3-k0').path.source).j,'21952/9'));
test('rational scaling preserves j and changes the exact discriminant',()=>{
  const p=byId('rational-scale').path,s=curveInvariants(p.source),t=curveInvariants(p.target);assert.equal(s.j,t.j);assert.notEqual(s.discriminant,t.discriminant);
});
test('known conductor-11 invariants on completed-square model',()=>{
  const c=curveInvariants(byId('five-11a').path.source);assert.equal(c.discriminant,'-161051');assert.equal(c.j,'-122023936/161051');
});
test('degree-5 kernel contains both rational x coordinates',()=>{
  const p=byId('five-11a').path;assert.equal(tracePoint(p,'5','11/2').at(-1).infinity,true);assert.equal(tracePoint(p,'16','121/2').at(-1).infinity,true);
});
test('point at infinity survives the path',()=>assert.equal(tracePoint(byId('doubling-6').path,'','',{infinity:true}).every(p=>p.infinity),true));
test('off-curve point is rejected',()=>assert.throws(()=>tracePoint(byId('congruent-6').path,'12','35'),/not on the source/));
test('zero denominators, floats and large input rejected',()=>{
  for(const x of ['1/0','1.5','1e6','9'.repeat(311)])assert.throws(()=>parseQ(x));
});
test('negative denominator in wire pairs is normalized',()=>assert.equal(formatQ(parseQ(['1','-2'])),'-1/2'));
test('singular curve rejected',()=>assert.throws(()=>curveInvariants({a2:['0','1'],a4:['0','1'],a6:['0','1']}),/Singular/));
test('too many maps and invalid scalars bounded',()=>{
  assert.throws(()=>tracePoint({steps:Array(17)},'0','0'),/size/);assert.throws(()=>scalarPoint(byId('congruent-6').path.source,'12','36',100));
});
test('Sage export embeds JSON as data and checks full identities',()=>{
  const script=sageScript(byId('five-11a').path);assert.match(script,/json.loads/);assert.match(script,/M\*\*2\*D\*\*3/);assert.match(script,/native ETF/);
});
