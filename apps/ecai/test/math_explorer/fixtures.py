"""Independent Python data generator for tests, NOT the native Erlang engine.
Native ETF identifiers are replaced with clearly scoped fixture hashes.
"""
from fractions import Fraction as Q
from collections import deque
import hashlib,json
from reference_checker import invariants,required_power,floor_root,isomorphic_q,pathcheck


def wire(v):
    if isinstance(v,Q):return [str(v.numerator),str(v.denominator)]
    if isinstance(v,dict):return {k:wire(x) for k,x in v.items()}
    if isinstance(v,list):return [wire(x) for x in v]
    return v

def digest(v):return hashlib.sha256(('PYTHON-TEST-FIXTURE:'+json.dumps(v,sort_keys=True)).encode()).hexdigest().upper()
def curve(a,b,c):return wire(dict(kind='elliptic_curve',field='q',a2=Q(a),a4=Q(b),a6=Q(c)))
def poly(values):
    p=[Q(x) for x in values]
    while p and p[-1]==0:p.pop()
    return wire(p)

def two(e,r):
    a,b,c=pathcheck.curve(e)
    assert r**3+a*r*r+b*r+c==0
    aa=a+3*r;bb=b+2*a*r+3*r*r
    t=curve(-2*aa,aa*aa-4*bb,0)
    m=dict(kind='isogeny',domain=e,codomain=t,degree=2,
        x_num=poly([r*r-aa*r+bb,aa-2*r,1]),x_den=poly([-r,1]),
        y_num=poly([r*r-bb,-2*r,1]),y_den=poly([r*r,-2*r,1]))
    pathcheck.verify_map(m)
    return m

def certificate(s,t):
    base=wire(dict(schema=1,scope='q_isomorphism',checker='python_fixture_q_classifier',formal_proof=False,
        source_id=digest(s),target_id=digest(t),source_invariants=invariants(s),target_invariants=invariants(t)))
    req=required_power(s,t)
    if req is None:return dict(base,relation='non_isomorphic',reason='different_j_invariants')
    k,ratio,reason=req
    power=dict(exponent=k,ratio=wire(ratio),exact=isomorphic_q(s,t))
    if ratio<0:power.update(obstruction='negative_even_power',denominator=ratio.denominator)
    else:
        n,d=floor_root(ratio.numerator,k),floor_root(ratio.denominator,k)
        power.update(numerator_floor=n,denominator_floor=d)
        if not power['exact']:power['obstruction']='non_integral_root_bracket'
    base['power_test']=power
    if not power['exact']:return dict(base,relation='non_isomorphic',reason=reason)
    u=Q(n,d);power['root']=wire(u)
    a,_,_=pathcheck.curve(s);at,_,_=pathcheck.curve(t);shift=(u*u*a-at)/3
    m=dict(kind='isogeny',domain=s,codomain=t,degree=1,x_num=poly([shift,u*u]),x_den=poly([1]),y_num=poly([u**3]),y_den=poly([1]))
    check=map_receipt(m)
    return dict(base,relation='isomorphic',reason='checked_rational_scaling_and_translation',forward_scale=wire(u),x_shift=wire(shift),witness=m,witness_check=check)

def map_receipt(m):
    pathcheck.verify_map(m)
    return dict(status='verified',scope='rational_map_identity',checker='python_fixture_map_checker',
        formal_proof=False,degree=m['degree'],degree_checked=True,origin_preserved=True,
        polynomial_identity='zero',source_id=digest(m['domain']),target_id=digest(m['codomain']),map_id=digest(m))

def path(seed,steps):
    target=seed if not steps else steps[-1]['map']['codomain']
    p=dict(schema=1,kind='mathematical_path',source=seed,target=target,steps=steps,hops=len(steps),total_cost=len(steps),total_degree=str(2**len(steps)))
    p['id']=digest(p)
    p['verification']=dict(status='verified',scope='composed_rational_isogenies',checker='python_fixture_path_checker',formal_proof=False,
        source_id=digest(seed),target_id=digest(target),total_degree=str(2**len(steps)),path_id=p['id'],steps=[map_receipt(s['map']) for s in steps])
    pathcheck.verify_document(p)
    return p

def explore(seed=None,depth=2,max_curves=24,numerator=8,denominator=4):
    seed=seed or curve(0,-1,0);rows=[];seen=set();reps=[];todo=deque([(seed,[])])
    roots=sorted({Q(n,d) for n in range(-numerator,numerator+1) for d in range(1,denominator+1)},key=lambda r:(r.numerator,r.denominator))
    stop='bounded_search_exhausted';stats=dict(expanded_models=0,root_evaluations=0,kernels_found=0,checked_maps=0,revisited_models=0,depth_frontier_models=0)
    def add(e,steps):
        group=next((i+1 for i,r in enumerate(reps) if isomorphic_q(r,e)),len(reps)+1)
        if group==len(reps)+1:reps.append(e)
        p=path(seed,steps);raw=json.dumps(p,separators=(',',':'))
        rows.append(dict(model_id=digest(e),curve=e,depth=len(steps),path_json=raw,path_id=p['id'],artifact_sha256=hashlib.sha256(raw.encode()).hexdigest().upper(),
            comparison_to_source=certificate(seed,e),local_class=group,representative_id=digest(reps[group-1]),class_certificate=certificate(reps[group-1],e)))
        seen.add(digest(e))
    add(seed,[])
    while todo and stop=='bounded_search_exhausted':
        e,steps=todo.popleft()
        if len(steps)>=depth:stats['depth_frontier_models']+=1;continue
        stats['expanded_models']+=1
        a,b,c=pathcheck.curve(e)
        for r in roots:
            stats['root_evaluations']+=1
            if r**3+a*r*r+b*r+c:continue
            stats['kernels_found']+=1;m=two(e,r);stats['checked_maps']+=1;t=m['codomain']
            if digest(t) in seen:stats['revisited_models']+=1;continue
            if len(rows)>=max_curves:stop='model_budget';break
            ss=steps+[dict(map=m,cost=1,origins=['Independent Python test generator, not native execution'])]
            add(t,ss);todo.append((t,ss))
    noniso=sum(r['comparison_to_source']['relation']=='non_isomorphic' for r in rows)
    return dict(schema=1,kind='mathematical_exploration',source=seed,bounds=dict(max_depth=depth,max_curves=max_curves,numerator_bound=numerator,denominator_bound=denominator,timeout_ms=8000),
        stop_reason=stop,completed_within_declared_bounds=stop=='bounded_search_exhausted',global_completeness='not_claimed',novel_to_mathematics='not_claimed',
        elapsed_ms=0,summary=dict(retained_models=len(rows),reachable_other_models=len(rows)-1,non_isomorphic_to_source_models=noniso,isomorphic_to_source_other_models=len(rows)-noniso-1,local_q_classes=len(reps),non_source_q_classes=len(reps)-1),
        stats=stats,results=rows,formal_proof=False,note='Independent Python test fixture. Not a native Erlang run; fixture identities are not ETF hashes.')
