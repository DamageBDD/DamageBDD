#!/usr/bin/env python3
"""Independently reconstruct Food Rescue v1 evidence using Python's standard library.

Checks checksum, fixed version/scope, exact known fixture, both planners, release
checks, ledger, recall transitions and metrics. No JavaScript execution or server
trust is required. This is consistency verification, not source authentication or
food-safety certification. Input limit: 1 MiB; no duplicate keys or JSON floats.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

VERSION='food-rescue-v1'
SCOPE='Synthetic browser-local whole-lot planning and recall simulation. Not food-safety certification, live sensor provenance, native ECAI retrieval or a DamageBDD backend run.'
SCENARIOS=['everyday','road-closure','cold-chain','missing-record','recall','late-recall','demand-surge','van-outage']
DEFAULTS={'capacityKg':160,'delayMinutes':0}
MAX_BYTES=1024*1024

def canonical(value: Any) -> str:
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)

def fixture(scenario: str, controls: dict[str,int]) -> dict:
    if scenario not in SCENARIOS: raise ValueError('Unknown scenario')
    if not isinstance(controls,dict) or set(controls)!={'capacityKg','delayMinutes'}: raise ValueError('Invalid controls')
    for key,lo,hi,step in [('capacityKg',80,180,10),('delayMinutes',0,30,5)]:
        v=controls[key]
        if type(v) is not int or not lo<=v<=hi or (v-lo)%step: raise ValueError('Invalid '+key)
    lots=[
      dict(id='TOM-01',name='Tomatoes',kg=80,batch='GROW-11',cold=False,expires=70,readings=[]),
      dict(id='LEAF-02',name='Leafy greens',kg=60,batch='GROW-12',cold=True,expires=50,readings=[3,4,4]),
      dict(id='BREAD-03',name='Bread',kg=100,batch='BAKE-18',cold=False,expires=250,readings=[]),
      dict(id='YOG-04',name='Yoghurt · lot A',kg=50,batch='DAIRY-42',cold=True,expires=145,readings=[3,3,4]),
      dict(id='YOG-05',name='Yoghurt · lot B',kg=40,batch='DAIRY-42',cold=True,expires=220,readings=[4,4,3]),
      dict(id='BERRY-06',name='Berries',kg=70,batch='GROW-13',cold=True,expires=140,readings=[3,4,3])]
    if scenario=='cold-chain': lots[5]['readings']=[3,9,8]
    if scenario=='missing-record': lots[1]['readings']=[3,None,4]
    nodes=[dict(id=i,name=n,x=x,y=y) for i,n,x,y in [
      ('depot','Rescue hub',105,215),('west','West junction',280,215),('east','East junction',435,215),
      ('north','North bypass',280,80),('kitchen','Community kitchen',590,95),
      ('pantry','Neighbourhood pantry',645,285),('shelter','Evening shelter',310,395)]]
    edges=[dict(id=i,a=a,b=b,minutes=m) for i,a,b,m in [
      ('hub-west','depot','west',8),('bridge','west','east',4),('east-kitchen','east','kitchen',6),
      ('east-pantry','east','pantry',8),('west-shelter','west','shelter',14),('hub-north','depot','north',10),('north-kitchen','north','kitchen',18)]]
    timetable=[dict(id=i,vehicle=v,destination=d,depart=t) for i,v,d,t in [
      ('A1','VAN-A','kitchen',0),('B1','VAN-B','pantry',0),('A2','VAN-A','shelter',90),
      ('B2','VAN-B','kitchen',90),('A3','VAN-A','pantry',180),('B3','VAN-B','shelter',180)]]
    return dict(version=VERSION,scenario=scenario,controls=copy.deepcopy(controls),horizon=270,
      policy=dict(id='DEMO-COLD-01',maxTemperatureC=5,requiredReadings=3,expiryExclusive=True,wholeLots=True),
      lots=lots,nodes=nodes,edges=edges,closedEdges=['bridge'] if scenario=='road-closure' else [],
      destinations=[dict(id='kitchen',name='Community kitchen',demandKg=200 if scenario=='demand-surge' else 160,cold=True),
        dict(id='pantry',name='Neighbourhood pantry',demandKg=180 if scenario=='demand-surge' else 140,cold=True),
        dict(id='shelter',name='Evening shelter',demandKg=120 if scenario=='demand-surge' else 100,cold=False)],
      vehicles=[dict(id='VAN-A',available=True,cold=True),dict(id='VAN-B',available=scenario!='van-outage',cold=True)],
      timetable=timetable,
      recalls=[dict(batch='DAIRY-42',at=0,reason='Synthetic supplier recall')] if scenario=='recall' else [],
      incidents=[dict(batch='DAIRY-42',at=30,reason='Synthetic supplier recall received at 09:30')] if scenario=='late-recall' else [])

def shortest_path(world:dict,target:str) -> dict|None:
    distance={n['id']:10**9 for n in world['nodes']};distance['depot']=0
    paths={'depot':['depot']};visited=set()
    while len(visited)<len(distance):
        current=min((n for n in distance if n not in visited),key=lambda n:(distance[n],n))
        if distance[current]==10**9:break
        visited.add(current)
        for e in world['edges']:
            if e['id'] in world['closedEdges']:continue
            nxt=e['b'] if e['a']==current else e['a'] if e['b']==current else None
            if nxt and distance[current]+e['minutes']<distance[nxt]:
                distance[nxt]=distance[current]+e['minutes'];paths[nxt]=paths[current]+[nxt]
    return dict(nodes=paths[target],minutes=distance[target]) if target in paths else None

def trips(world:dict)->list[dict]:
    result=[]
    for original in world['timetable']:
        r=shortest_path(world,original['destination']);depart=original['depart']+world['controls']['delayMinutes']
        result.append(dict(original,depart=depart,arrival=depart+r['minutes'] if r else None,
          returns=depart+2*r['minutes'] if r else None,route=r))
    return result

def disposition(world:dict,lot:dict,minute:int=0,incidents:bool=False)->dict:
    records=world['recalls']+(world['incidents'] if incidents else [])
    if any(r['batch']==lot['batch'] and r['at']<=minute for r in records):
        return dict(state='quarantined',reason='Recalled batch '+lot['batch'])
    if lot['cold'] and any(type(v) is int and v>world['policy']['maxTemperatureC'] for v in lot['readings']):
        return dict(state='quarantined',reason='Temperature exceeds synthetic demo rule')
    if lot['cold'] and (len(lot['readings'])!=world['policy']['requiredReadings'] or any(type(v) is not int for v in lot['readings'])):
        return dict(state='unverifiable',reason='Required temperature evidence is missing')
    return dict(state='available',reason='Eligible under the synthetic rules')

def candidate_reason(world:dict,lot:dict,trip:dict)->str|None:
    d=disposition(world,lot)
    if d['state']!='available':return d['reason']
    vehicle=next(v for v in world['vehicles'] if v['id']==trip['vehicle'])
    destination=next(v for v in world['destinations'] if v['id']==trip['destination'])
    if not vehicle['available']:return 'Vehicle unavailable'
    if not trip['route']:return 'No open route'
    if lot['cold'] and (not vehicle['cold'] or not destination['cold']):return 'Destination or vehicle cannot accept chilled stock'
    if trip['arrival']>=lot['expires']:return 'Arrival is not before expiry'
    if trip['returns']>world['horizon']:return 'Trip exceeds the demo horizon'
    following=sorted((t for t in world['timetable'] if t['vehicle']==trip['vehicle'] and t['depart']+world['controls']['delayMinutes']>trip['depart']),key=lambda t:t['depart'])
    if following and trip['returns']>following[0]['depart']+world['controls']['delayMinutes']:return 'Vehicle cannot return before next departure'
    return None

def score(world:dict,assignments:list[dict])->dict:
    lots={l['id']:l for l in world['lots']};ts={t['id']:t for t in trips(world)}
    return dict(kg=sum(lots[a['lot']]['kg'] for a in assignments),
      kgMinutes=sum(lots[a['lot']]['kg']*ts[a['trip']]['arrival'] for a in assignments),
      travelMinutes=sum(2*ts[t]['route']['minutes'] for t in {a['trip'] for a in assignments}))

def greedy_plan(world:dict)->dict:
    ts=trips(world);used={};demand={};assignments=[]
    for lot in sorted(world['lots'],key=lambda l:(l['expires'],l['id'])):
        for t in sorted((t for t in ts if candidate_reason(world,lot,t) is None),key=lambda t:(t['arrival'],t['id'])):
            dest=next(d for d in world['destinations'] if d['id']==t['destination'])
            if used.get(t['id'],0)+lot['kg']>world['controls']['capacityKg'] or demand.get(t['destination'],0)+lot['kg']>dest['demandKg']:continue
            used[t['id']]=used.get(t['id'],0)+lot['kg'];demand[t['destination']]=demand.get(t['destination'],0)+lot['kg']
            assignments.append(dict(lot=lot['id'],trip=t['id']));break
    order={l['id']:idx for idx,l in enumerate(world['lots'])};assignments.sort(key=lambda a:order[a['lot']])
    return dict(method='fefo-earliest',assignments=assignments,score=score(world,assignments))

def rescue_plan(world:dict)->dict:
    ts=trips(world);lots=world['lots'];used=[0]*len(ts);demand={};current=[];best=None;nodes=0
    choices=[[(idx,t) for idx,t in enumerate(ts) if candidate_reason(world,l,t) is None] for l in lots]
    def visit(i:int,kg:int,kg_minutes:int,travel:int)->None:
        nonlocal best,nodes
        nodes+=1
        if best and kg+sum(l['kg'] for l in lots[i:])<best['score']['kg']:return
        if i==len(lots):
            candidate=dict(kg=kg,kgMinutes=kg_minutes,travelMinutes=travel)
            if best is None or (-kg,kg_minutes,travel)<(-best['score']['kg'],best['score']['kgMinutes'],best['score']['travelMinutes']):
                best=dict(assignments=copy.deepcopy(current),score=candidate)
            return
        lot=lots[i]
        for idx,t in choices[i]:
            dest=next(d for d in world['destinations'] if d['id']==t['destination'])
            if used[idx]+lot['kg']>world['controls']['capacityKg'] or demand.get(t['destination'],0)+lot['kg']>dest['demandKg']:continue
            extra=2*t['route']['minutes'] if used[idx]==0 else 0
            used[idx]+=lot['kg'];demand[t['destination']]=demand.get(t['destination'],0)+lot['kg'];current.append(dict(lot=lot['id'],trip=t['id']))
            visit(i+1,kg+lot['kg'],kg_minutes+lot['kg']*t['arrival'],travel+extra)
            current.pop();used[idx]-=lot['kg'];demand[t['destination']]-=lot['kg']
        visit(i+1,kg,kg_minutes,travel)
    visit(0,0,0,0)
    return dict(method='bounded-exact',**best,searchNodes=nodes)

def validate_plan(world:dict,assignments:list[dict])->None:
    if not isinstance(assignments,list) or len(assignments)>len(world['lots']):raise ValueError('Invalid assignment list')
    ts={t['id']:t for t in trips(world)};lots={l['id']:l for l in world['lots']};seen=set();loads={};demand={}
    for a in assignments:
        if not isinstance(a,dict) or set(a)!={'lot','trip'} or a['lot'] not in lots or a['trip'] not in ts:raise ValueError('Invalid assignment')
        lot=lots[a['lot']];trip=ts[a['trip']]
        if lot['id'] in seen:raise ValueError('Duplicate lot')
        seen.add(lot['id']);reason=candidate_reason(world,lot,trip)
        if reason:raise ValueError(reason)
        loads[trip['id']]=loads.get(trip['id'],0)+lot['kg'];demand[trip['destination']]=demand.get(trip['destination'],0)+lot['kg']
    if any(v>world['controls']['capacityKg'] for v in loads.values()):raise ValueError('Vehicle capacity exceeded')
    if any(demand.get(d['id'],0)>d['demandKg'] for d in world['destinations']):raise ValueError('Demand exceeded')

def execute_plan(world:dict,plan:dict)->dict:
    validate_plan(world,plan['assignments']);ts=trips(world)
    records=[dict(lot=l['id'],kg=l['kg'],batch=l['batch'],**disposition(world,l),location='depot',trip=None,deliveredAt=None) for l in world['lots']]
    trace=[dict(at=0,type='start',message='Inventory checked against the current synthetic rules.',records=copy.deepcopy(records))]
    events=[dict(at=i['at'],order=0,type='recall',batch=i['batch']) for i in world['incidents']]
    for t in ts:
        if any(a['trip']==t['id'] for a in plan['assignments']):
            events += [dict(at=t['depart'],order=1,type='dispatch',trip=t['id']),dict(at=t['arrival'],order=2,type='arrival',trip=t['id'])]
    events.sort(key=lambda e:(e['at'],e['order'],e.get('trip','')));ledger=[];gate=[]
    for e in events:
        if e['type']=='recall':
            for r in records:
                if r['batch']!=e['batch']:continue
                previous=r['state'];r['state']='recall-hold' if previous=='delivered' else 'quarantined';r['reason']='Recalled batch '+e['batch']
                ledger.append(dict(at=e['at'],action='recipient-hold' if previous=='delivered' else 'recall-hold',lot=r['lot'],kg=r['kg'],location=r['location']))
        else:
            t=next(t for t in ts if t['id']==e['trip'])
            for a in plan['assignments']:
                if a['trip']!=t['id']:continue
                lot=next(l for l in world['lots'] if l['id']==a['lot']);r=next(r for r in records if r['lot']==a['lot'])
                if e['type']=='arrival' and r['trip']!=t['id']:continue
                eligible=disposition(world,lot,e['at'],True);passes=eligible['state']=='available' and e['at']<lot['expires']
                reason='Current recall, evidence and expiry checks pass' if passes else eligible['reason'] if eligible['state']!='available' else 'Expired before release'
                gate.append(dict(at=e['at'],stage=e['type'],lot=lot['id'],trip=t['id'],passed=passes,reason=reason))
                if not passes:
                    r['state']='unverifiable' if eligible['state']=='unverifiable' else 'quarantined';r['reason']=eligible['reason'] if eligible['state']!='available' else 'Expired before release'
                    if e['type']=='arrival':r['location']=t['destination']
                    ledger.append(dict(at=e['at'],action='release-blocked',lot=lot['id'],kg=lot['kg'],location=r['location']))
                elif e['type']=='dispatch':
                    r.update(state='in-transit',location=t['vehicle'],trip=t['id'],reason='In transit; check again on arrival')
                    ledger.append(dict(at=e['at'],action='loaded',lot=lot['id'],kg=lot['kg'],location=t['vehicle']))
                else:
                    r.update(state='delivered',location=t['destination'],deliveredAt=e['at'],reason='Delivered before expiry under the demo rules')
                    ledger.append(dict(at=e['at'],action='delivered',lot=lot['id'],kg=lot['kg'],location=t['destination']))
        message='Recall received: '+e['batch']+'. Hold all matching lots.' if e['type']=='recall' else e['trip']+' '+('dispatch checked' if e['type']=='dispatch' else 'arrival checked')
        trace.append(dict(at=e['at'],type=e['type'],message=message,records=copy.deepcopy(records)))
    for r in records:
        if r['state']=='available':r.update(state='unallocated',reason='No assignment in this plan; not counted as rescued')
    trace.append(dict(at=world['horizon'],type='end',message='End of demo window. Only eligible deliveries count as rescued.',records=copy.deepcopy(records)))
    mass=lambda states:sum(r['kg'] for r in records if r['state'] in states)
    metrics=dict(totalKg=sum(l['kg'] for l in world['lots']),rescuedKg=mass(['delivered']),quarantineKg=mass(['quarantined','recall-hold']),unverifiableKg=mass(['unverifiable']),unallocatedKg=mass(['unallocated']),recipientHoldKg=mass(['recall-hold']))
    metrics['demandKg']=sum(d['demandKg'] for d in world['destinations']);metrics['unmetKg']=metrics['demandKg']-metrics['rescuedKg']
    delivered=[e for e in ledger if e['action']=='delivered'];lots={l['id']:l for l in world['lots']}
    checks=[
      dict(id='mass',label='Every kilogram accounted for',passed=metrics['totalKg']==sum(metrics[k] for k in ['rescuedKg','quarantineKg','unverifiableKg','unallocatedKg'])),
      dict(id='eligible',label='No held stock counted as rescued',passed=all(disposition(world,lots[r['lot']],world['horizon'],True)['state']=='available' for r in records if r['state']=='delivered')),
      dict(id='expiry',label='Deliveries arrive before expiry',passed=all(e['at']<lots[e['lot']]['expires'] for e in delivered)),
      dict(id='capacity',label='Vehicle loads stay within capacity',passed=all(sum(lots[a['lot']]['kg'] for a in plan['assignments'] if a['trip']==t['id'])<=world['controls']['capacityKg'] for t in ts)),
      dict(id='demand',label='Recipient allocations do not exceed demand',passed=all(sum(e['kg'] for e in delivered if e['location']==d['id'])<=d['demandKg'] for d in world['destinations'])),
      dict(id='unique',label='No lot is delivered twice',passed=len({e['lot'] for e in delivered})==len(delivered)),
      dict(id='gate',label='Every delivery has a passing release check',passed=all(any(g['stage']=='arrival' and g['lot']==e['lot'] and g['at']==e['at'] and g['passed'] for g in gate) for e in delivered))]
    return dict(plan=plan,records=records,ledger=ledger,gate=gate,trace=trace,metrics=metrics,checks=checks)

def run(scenario:str='everyday',controls:dict|None=None)->dict:
    world=fixture(scenario,DEFAULTS if controls is None else controls)
    return dict(version=VERSION,scope=SCOPE,world=world,baseline=execute_plan(world,greedy_plan(world)),rescue=execute_plan(world,rescue_plan(world)))

def no_duplicates(pairs:list)->dict:
    out={}
    for k,v in pairs:
        if k in out:raise ValueError('Duplicate JSON key: '+k)
        out[k]=v
    return out

def reject_number(value:str):raise ValueError('Non-integer or non-finite JSON number rejected')

def load(path:Path)->dict:
    if path.stat().st_size>MAX_BYTES:raise ValueError('Evidence exceeds 1 MiB limit')
    with path.open(encoding='utf-8') as f:
        return json.load(f,object_pairs_hook=no_duplicates,parse_float=reject_number,parse_constant=reject_number)

def verify(evidence:dict)->dict:
    if not isinstance(evidence,dict) or set(evidence)!={'payload','sha256'}:raise ValueError('Invalid evidence envelope')
    payload=evidence['payload']
    if not isinstance(payload,dict) or set(payload)!={'schema','scope','result'} or payload['schema']!=VERSION or payload['scope']!=SCOPE:raise ValueError('Unknown evidence schema or scope')
    digest=hashlib.sha256(canonical(payload).encode()).hexdigest()
    if type(evidence['sha256']) is not str or evidence['sha256']!=digest:raise ValueError('SHA-256 mismatch')
    result=payload['result']
    if not isinstance(result,dict) or not isinstance(result.get('world'),dict):raise ValueError('Missing fixture')
    world=result['world'];expected=run(world.get('scenario'),world.get('controls'))
    if canonical(result)!=canonical(expected):raise ValueError('Evidence differs from independent fixture/planner/ledger reconstruction')
    return dict(status='verified',scenario=world['scenario'],rescued_kg=expected['rescue']['metrics']['rescuedKg'],
      baseline_kg=expected['baseline']['metrics']['rescuedKg'],checks=14,scope='Known synthetic fixture consistency; not authenticity, food safety or live execution.')

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('evidence',type=Path);args=parser.parse_args()
    try:print(json.dumps(verify(load(args.evidence)),indent=2));return 0
    except (OSError,ValueError,TypeError,KeyError,RecursionError) as exc:print('Verification failed: '+str(exc),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
