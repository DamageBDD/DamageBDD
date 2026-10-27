import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createHash} from 'node:crypto';
import {generate3DMesh,meshToOBJ,sha256Hex,sha256Fallback,experimentBundle,initMath3D} from '../../priv/static/js/ecai-math-3d.js';

const OPTIONS=[
  {shape:'dragonfly',detail:18,twist:1},
  {shape:'elliptic-torus',detail:18,twist:2},
  {shape:'double-helix',detail:18,twist:3}
];
test('all 3D geometries are finite, bounded indexed triangle meshes',()=>{
  for(const config of OPTIONS){
    const mesh=generate3DMesh(config);
    assert.ok(mesh.vertices.length>200 && mesh.vertices.length<20000);
    assert.ok(mesh.faces.length>200 && mesh.faces.length<30000);
    assert.ok(mesh.vertices.every(p=>p.length===3 && p.every(x=>Number.isFinite(x))));
    assert.ok(mesh.faces.every(({a,b,c})=>[a,b,c].every(v=>Number.isInteger(v)&&v>=0&&v<mesh.vertices.length)));
    assert.ok(new Set(mesh.faces.map(x=>x.material)).size>=2);
  }
});
test('geometry and OBJ export are byte-for-byte deterministic',()=>{
  for(const config of OPTIONS) {
    const a=meshToOBJ(generate3DMesh(config)),b=meshToOBJ(generate3DMesh({...config}));
    assert.equal(a,b);assert.ok(a.startsWith('# ECAI visual geometry'));
    const positions=a.split('\n').filter(x=>x.startsWith('v '));
    const faces=a.split('\n').filter(x=>x.startsWith('f '));
    assert.equal(positions.length,generate3DMesh(config).vertices.length);
    assert.equal(faces.length,generate3DMesh(config).faces.length);
  }
});
test('changing a parameter changes reproducible mesh bytes',()=>{
  const original=meshToOBJ(generate3DMesh(OPTIONS[0]));
  assert.notEqual(original,meshToOBJ(generate3DMesh({...OPTIONS[0],twist:1.5})));
  assert.notEqual(original,meshToOBJ(generate3DMesh({...OPTIONS[0],detail:20})));
});
test('malformed input cannot allocate unbounded work',()=>{
  for(const options of [{shape:'invalid'}, {detail:1000},{detail:4},{twist:Infinity},{twist:-1}])assert.throws(()=>generate3DMesh(options));
});
test('SHA-256 agrees with Node reference digest',async()=>{
  for(const sample of ['hello world','ECAI geometry v1','\u0394\u00e9']) {
    assert.equal(await sha256Hex(sample),createHash('sha256').update(sample).digest('hex'));
    assert.equal(sha256Fallback(sample),createHash('sha256').update(sample).digest('hex'));
  }
  const long='Ecai3D🪁'.repeat(10000);
  assert.equal(sha256Fallback(long),createHash('sha256').update(long).digest('hex'));
});
test('manifest contains real mesh digests, provenance and explicit no-mint status',async()=>{
  const config=OPTIONS[0];const mesh=generate3DMesh(config);
  const result=await experimentBundle(config,mesh);
  assert.equal(result.receipt.mesh.sha256,createHash('sha256').update(result.obj).digest('hex'));
  assert.match(result.receipt.experiment_id,/^sha256:[0-9a-f]{64}$/);
  assert.equal(result.receipt.verification.exact_isogeny,false);
  assert.equal(result.receipt.verification.semantic_relation,false);
  assert.equal(result.receipt.provenance.blockchain_transactions,0);
  assert.match(result.metadata.media_url,/REPLACE_WITH_PINNED_OBJ_CID/);
  assert.equal(result.metadata.traits.experiment_sha256,result.receipt.experiment_id.slice(7));
  assert.deepEqual(result,await experimentBundle({...config},generate3DMesh({...config})));
});
test('3D controller is a no-op in non-browser environments',()=>{
  const c=initMath3D();c.setVisible(true);c.dispose();
});
