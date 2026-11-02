import test from 'node:test';
import assert from 'node:assert/strict';
import { awaitScheduleOperation, isPendingOperation } from '../../priv/static/js/schedule-operations.js';
const running={operation_id:'sop_1',status:'running',stage:'create_schedule'};
const complete={operation_id:'sop_1',status:'complete',result:{status:'active',id:'sv2_1'}};
const fast={sleep:async()=>{},intervalMs:0,maxReads:5};

test('legacy immediate result is unchanged',async()=>{
 const r={status:'ok'}; assert.equal(await awaitScheduleOperation(r,()=>assert.fail('no read'),fast),r);
});
test('only completion becomes success',async()=>{
 let n=0;const r=await awaitScheduleOperation(running,async()=>++n<3?running:complete,fast);
 assert.equal(n,3);assert.equal(r.status,'active');
});
test('lost observation stays pending, without a mutation retry',async()=>{
 let n=0;const r=await awaitScheduleOperation(running,async()=>{n++;throw Error('offline');},fast);
 assert.equal(n,1);assert.ok(isPendingOperation(r));assert.equal(r.operation_id,'sop_1');
});
test('polling is bounded',async()=>{
 let n=0;const r=await awaitScheduleOperation(running,async()=>{n++;return running;},{...fast,maxReads:2});
 assert.equal(n,2);assert.ok(isPendingOperation(r));
});
test('closed dialog stops observing, not the server operation',async()=>{
 const r=await awaitScheduleOperation(running,()=>assert.fail('no read'),{...fast,keepWaiting:()=>false});
 assert.ok(isPendingOperation(r));
});
test('expired browser observation is not a successful creation',async()=>{
 let t=0;const r=await awaitScheduleOperation(running,async()=>running,{...fast,now:()=>t++,timeoutMs:1});
 assert.ok(isPendingOperation(r));
});
test('uncertain outcome retains hash and warns against refunding',async()=>{
 await assert.rejects(()=>awaitScheduleOperation({...running,status:'reconciliation_required',error:'confirmation_timeout',tx_hash:'th_123'},null,fast),/th_123.*Do not fund again/);
});
test('preparation failure is not activation',async()=>{
 await assert.rejects(()=>awaitScheduleOperation({...running,status:'failed',stage:'preparing',error:'invalid_cron'},null,fast),/failed at preparing/);
});
test('obsolete signing response follows its successor',async()=>{
 const ids=[];const r=await awaitScheduleOperation({...running,status:'superseded',superseded_by:'sop_2'},async id=>{ids.push(id);return {...complete,operation_id:id};},fast);
 assert.deepEqual(ids,['sop_2']);assert.equal(r.status,'active');
});
test('cycles and malformed responses fail closed',async()=>{
 await assert.rejects(()=>awaitScheduleOperation({...running,status:'superseded',superseded_by:'sop_2'},async()=>({operation_id:'sop_2',status:'superseded',superseded_by:'sop_1'}),fast),/Invalid schedule operation chain/);
 await assert.rejects(()=>awaitScheduleOperation(running,async()=>({status:'ok'}),fast),/Invalid schedule operation response/);
 await assert.rejects(()=>awaitScheduleOperation({...running,status:'complete'},null,fast),/no completion result/);
});
test('wallet completion still requires the existing signature flow',async()=>{
 const result={status:'signing_required',stage:'approve_allowance',tx:'tx_fixture'};
 assert.deepEqual(await awaitScheduleOperation({...complete,result},null,fast),result);
});
test('unknown status cannot activate the success UI',async()=>{
 await assert.rejects(()=>awaitScheduleOperation({...running,status:'unexpected'},null,fast),/Unrecognized/);
});
