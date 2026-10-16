#!/usr/bin/env python3
"""Rebuild the bundled exact-isogeny examples. Build-time dependency: SymPy.

No network, Sage, secrets, or node is needed. Runtime previews use bundled JSON.
The independent reference checker checks every positive example; the negative
control must fail. ETF identities target the existing OTP 27+ codec. A separate
native test imports every fixture to validate those IDs with the real codec.
"""
from __future__ import annotations
import hashlib, json, struct, sys
from copy import deepcopy
from pathlib import Path
from fractions import Fraction as Q
import sympy as s
APP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(APP / 'test/math_pathfinder'))
from reference_checker import verify_document
x = s.Symbol('x')
OUT = APP / 'priv/static/math-samples'
JS = APP / 'priv/static/js/ecai-math-samples.js'
SAGE = 'https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/ell_curve_isogeny.html'
SCALAR = 'https://doc.sagemath.org/html/en/reference/arithmetic_curves/sage/schemes/elliptic_curves/hom_scalar.html'
LM11 = 'https://www.lmfdb.org/EllipticCurve/Q/11/a/2'

def rational(q):
    q=Q(str(q)); return [str(q.numerator), str(q.denominator)]
def unq(q): return s.Rational(*q)
def E(a,b,c): return dict(kind='elliptic_curve',field='q',a2=rational(a),a4=rational(b),a6=rational(c))
def f(e): return x**3+unq(e['a2'])*x*x+unq(e['a4'])*x+unq(e['a6'])
def poly(p):
    cs=list(reversed(s.Poly(p,x).all_coeffs()))
    while cs and cs[-1]==0: cs.pop()
    return [rational(c) for c in cs]
def fraction(r):
    n,d=s.fraction(s.cancel(r)); lead=s.Poly(d,x).LC()
    return poly(n/lead),poly(d/lead)
def M(e,t,d,X,Y):
    n,den=fraction(X); m,l=fraction(Y)
    return dict(kind='isogeny',domain=e,codomain=t,degree=d,x_num=n,x_den=den,y_num=m,y_den=l)
def expr(p): return sum(unq(c)*x**i for i,c in enumerate(p))
def mapxy(m): return (expr(m['x_num'])/expr(m['x_den']),expr(m['y_num'])/expr(m['y_den']))
def two(e,r=0):
    r=s.Rational(r); assert f(e).subs(x,r)==0
    a=unq(e['a2'])+3*r; b=unq(e['a4'])+2*unq(e['a2'])*r+3*r*r
    u=x-r; return M(e,E(-2*a,a*a-4*b,0),2,(u*u+a*u+b)/u,(u*u-b)/(u*u))
def three(e):
    assert unq(e['a2'])==unq(e['a4'])==0
    b=unq(e['a6']); return M(e,E(0,0,-27*b),3,(x**3+4*b)/x**2,(x**3-8*b)/x**3)
def scale(e,u):
    u=s.Rational(u); assert u
    a,b,c=[unq(e[k]) for k in ('a2','a4','a6')]
    return M(e,E(a*u**2,b*u**4,c*u**6),1,x*u**2,u**3)
def velu5():
    e=E(-1,-10,'-79/4'); a,b,c=[unq(e[k]) for k in ('a2','a4','a6')]
    # P=(5,11/2), 2P=(16,-121/2) after completing the square.
    # Sum x(P+Q)-x(Q) over ±P, ±2P, using y²=f(x).
    X=x
    for r,t in [(s.Integer(5),s.Rational(11,2)),(s.Integer(16),s.Rational(121,2))]:
        assert t*t==f(e).subs(x,r)
        X+=2*(f(e)+t*t)/(x-r)**2-2*a-2*x-4*r
    X=s.cancel(X); Y=s.diff(X,x)
    # Recover codomain coefficients from the exact identity, then check it.
    A,B,C=s.symbols('A B C')
    residual=s.together(f(e)*Y**2-X**3-A*X**2-B*X-C)
    sol=s.solve(s.Poly(s.fraction(residual)[0],x).all_coeffs(),[A,B,C],dict=True)
    assert len(sol)==1
    t=E(sol[0][A],sol[0][B],sol[0][C])
    assert t==E(-1,-7820,'-1054319/4')
    return M(e,t,5,X,Y)

# Restricted ETF encoder: only tags used by the existing mathematical identities.
class Atom(str): pass
def etf(v):
    if isinstance(v,Atom):
        b=v.encode(); return b'w'+bytes([len(b)])+b
    if isinstance(v,str): v=v.encode()
    if isinstance(v,bytes): return b'm'+struct.pack('>I',len(v))+v
    if isinstance(v,int):
        if 0<=v<256: return b'a'+bytes([v])
        if -(1<<31)<=v<(1<<31): return b'b'+struct.pack('>i',v)
        b=abs(v).to_bytes((abs(v).bit_length()+7)//8,'little')
        return b'n'+bytes([len(b),int(v<0)])+b
    if isinstance(v,tuple): return b'h'+bytes([len(v)])+b''.join(map(etf,v))
    if isinstance(v,list):
        return b'j' if not v else b'l'+struct.pack('>I',len(v))+b''.join(map(etf,v))+b'j'
    raise TypeError(v)
def H(domain,t):
    b=domain.encode(); return hashlib.sha256(struct.pack('>I',len(b))+b+b'\x83'+etf(t)).hexdigest().upper()
def cq(q): return tuple(map(int,q))
def cid(e): return H('ECAI-MATH-CURVE-V1',(Atom('q'),*(cq(e[k]) for k in ('a2','a4','a6'))))
def mid(m): return H('ECAI-MATH-ISOGENY-V1',(cid(m['domain']),cid(m['codomain']),m['degree'],*([cq(c) for c in m[k]] for k in ('x_num','x_den','y_num','y_den'))))
def path(maps):
    steps=[dict(map=m,cost=1,origins=['ECAI curated exact examples v1']) for m in maps]
    p=dict(schema=1,kind='mathematical_path',source=maps[0]['domain'],target=maps[-1]['codomain'],steps=steps,
           hops=len(maps),total_cost=len(maps),total_degree=str(s.prod(m['degree'] for m in maps)))
    p['id']=H('ECAI-MATH-PATH-V1',(cid(p['source']),cid(p['target']),[(mid(z['map']),z['cost'],z['origins']) for z in steps]))
    return p

def point(x,y,label=None): return dict(x=str(x),y=str(y),label=label or f'({x}, {y})')
def compose(maps):
    X=x; Y=s.Integer(1)
    for m in maps:
        a,b=mapxy(m); Y=s.cancel(Y*b.subs(x,X)); X=s.cancel(a.subs(x,X))
    return X,Y

def doubling(e):
    a=unq(e['a2']); F=f(e); L=s.diff(F,x)
    X=s.cancel(L*L/(4*F)-a-2*x)
    Y=s.cancel(-1+L*(x-X)/(2*F)); return X,Y

samples=[]
def add(id,title,category,maps,summary,question,points,discover=False,refs=None):
    p=path(maps); result=verify_document(p)
    for pt in points:
        assert s.Rational(pt['y'])**2==f(p['source']).subs(x,s.Rational(pt['x']))
    samples.append(dict(id=id,title=title,category=category,summary=summary,question=question,
        can_discover=discover,expected='accept',path=p,
        model_ids=[cid(p['source'])]+[cid(m['codomain']) for m in maps],map_ids=[mid(m) for m in maps],
        points=points,reference_check=result,references=refs or [dict(title='SageMath: explicit isogenies',url=SAGE)],
        bounds=dict(max_depth=min(3,len(maps)),max_curves=64,numerator_bound=8,denominator_bound=4)))

base=E(0,-36,0); a=two(base); b=two(a['codomain']); c=scale(b['codomain'],s.Rational(1,2))
assert all(s.cancel(u-v)==0 for u,v in zip(compose([a,b,c]),doubling(base)))
add('doubling-6','Doubling on the n = 6 curve','Endomorphisms',[a,b,c],
    'Factor [2] into two degree-2 quotients and a rational scaling. The path returns to the same model but has degree 4, not degree 1.',
    'Trace P = (12, 36). Why is [2]P = (25/4, −35/8)? Compare this nontrivial endomorphism with the zero-hop identity returned by endpoint-only search.',
    [point(12,36),point(18,72),point(6,0,'Kernel point (6, 0)')],refs=[dict(title='SageMath: scalar multiplication has degree m²',url=SCALAR)])
add('congruent-6','Congruent-number curve: n = 6','Degree 2',[a],
    'Work on y² = x³ − 36x and its quotient y² = x³ + 144x. The non-torsion example P = (12, 36) maps to (9, 45).',
    'Evaluate (12, 36), then (18, 72). The source point gives the 3–4–5 rational right triangle of area 6.',
    [point(12,36),point(18,72),point(0,0,'Kernel point (0, 0)')],True)
leg=E(-4,3,0)
for r in [0,1,3]:
    add(f'legendre-3-k{r}',f'Legendre λ = 3 · kernel ({r}, 0)','Non-CM / kernels',[two(leg,r)],
        'Three rational 2-torsion subgroups give three quotient models. Inspect the j-invariants and compare kernels 0, 1 and 3.',
        'Switch between the three Legendre examples. The source has j = 21952/9; equivalent input equations do not make these maps identical.',
        [point(r,0,'Selected kernel'),point([k for k in [0,1,3] if k!=r][0],0,'Other 2-torsion point')],True)
rational_e=E('-3/2','-1/4','3/8')
add('half-kernel','A rational kernel at x = 1/2','Rational coefficients',[two(rational_e,s.Rational(1,2))],
    'Translate y² = u³ − u by u = x − 1/2. The model and the kernel now have nonintegral coordinates; no floating-point approximation is needed.',
    'Set the discovery denominator bound to 1, then to 2. All three rational kernel roots of this source have denominator 2.',
    [point('1/2',0),point('3/2',0),point('-1/2',0)],True)
mordell=E(0,0,1); t=three(mordell)
add('mordell-3','j = 0 · a degree-3 isogeny','Degree 3',[t],
    'The explicit map X = (x³ + 4)/x², Y = y(x³ − 8)/x³ connects y² = x³ + 1 to y² = x³ − 27.',
    'The order-3 point (0, 1) goes to infinity; (2, 3) maps to (3, 0). Native degree-2 discovery does not generate this map.',
    [point(2,3),point(0,1,'Kernel point (0, 1)'),point(-1,0)])
add('mixed-6','A mixed 3 × 2 composition','Mixed degree',[t,two(t['codomain'],3)],
    'Compose a degree-3 quotient with the rational 2-torsion quotient at (3, 0). The resulting map has degree 6.',
    'Follow (2, 3) → (3, 0) → O. The second kernel is on the intermediate curve, not the source.',
    [point(2,3),point(0,1),point(-1,0)])
u=three(t['codomain']); v=scale(u['codomain'],s.Rational(1,3))
# Compare with the independent chord-and-tangent expression [2]P + P.
dx,dy=doubling(mordell); slope=(dy-1)/(dx-x)
tx=s.cancel(f(mordell)*slope*slope-dx-x)
ty=s.cancel(-1+slope*(x-tx))
assert all(s.cancel(j-k)==0 for j,k in zip(compose([t,u,v]),(tx,ty)))
add('tripling-j0','Tripling at j = 0','Endomorphisms',[t,u,v],
    'Two degree-3 maps followed by scaling by 1/3 give [3] on y² = x³ + 1. The composite degree is 9.',
    'Evaluate the order-6 point (2, 3). Compare [3]P with P and −P. Endpoint equality alone does not identify a map.',
    [point(2,3),point(0,1),point(-1,0)],refs=[dict(title='SageMath: scalar multiplication has degree m²',url=SCALAR)])
five=velu5()
add('five-11a','Conductor 11 · rational 5-isogeny','Degree 5',[five],
    'Start from the completed-square model of 11.a2 (Cremona 11a1): y² = x³ − x² − 10x − 79/4. Quotient by its rational order-5 subgroup.',
    'Inspect the degree-5 X map and kernel x-coordinates 5 and 16. Here y means the original coordinate plus 1/2. This fixture is explicit, not found by degree-2 discovery.',
    [point(5,'11/2','Order-5 generator (5, 11/2)'),point(16,'121/2','Kernel point (16, 121/2)')],refs=[dict(title='LMFDB 11.a2: equation and rational 5-torsion',url=LM11),dict(title='SageMath: Vélu / explicit isogenies',url=SAGE)])
c0=E(1,-2,0); c1=two(c0); c2=two(c1['codomain']); c3=two(c2['codomain'])
add('noncm-eight','A non-CM degree-8 chain','Degree 8',[c1,c2,c3],
    'Three rational 2-isogenies produce a degree-8 composition across four exact models. The source is y² = x(x − 1)(x + 2).',
    'Discover the endpoints at max hops 2 and 3. Compare model discriminants, map degrees and the edge-weight sum.',
    [point(0,0),point(1,0),point(-2,0)],True)
add('rational-scale','Same j, different exact model','Isomorphisms',[scale(base,s.Rational(2,3))],
    'The degree-1 isomorphism (x, y) ↦ (4x/9, 8y/27) changes model coefficients and discriminant but preserves j.',
    'Compare the exact discriminants and j-invariants. Do not merge models merely because their j-invariants match.',
    [point(12,36),point(18,72),point(0,0)])
bad=deepcopy(a); bad['y_num'][0]=rational(37)
p=path([bad])
try: verify_document(p)
except ValueError as e: reason=str(e)
else: raise AssertionError('negative control unexpectedly verified')
samples.append(dict(id='tampered-control',title='Negative control: one altered coefficient',category='Verification challenge',
    summary='Change the Y numerator of the n = 6 quotient from x² + 36 to x² + 37. It still looks plausible; exact algebra must reject it.',
    question='Ask the node to check this candidate, or test (12, 36) locally. A stored label or an on-screen arrow cannot make a false identity true.',
    can_discover=False,expected='reject',path=p,model_ids=[cid(p['source']),cid(p['target'])],map_ids=[mid(bad)],
    points=[point(12,36)],reference_check=dict(status='rejected_as_expected',reason=reason,hashes_checked=False),
    references=[dict(title='SageMath: isogeny definition',url=SAGE)],bounds=dict(max_depth=1,max_curves=64,numerator_bound=8,denominator_bound=4)))
# Check the ETF implementation against the already-observed native IDs.
assert cid(E(0,-1,0))=='39A948A0F953C2DE66F20D051D40B2C33149472FD993D5D11545C873687479C9'
assert mid(two(E(0,-1,0)))=='9E498E8DF618B4D6680C5AE7E31CDE1B53D7090DB49BE81DF36F52554FD6E84F'
v1=two(E(0,-1,0));v2=two(v1['codomain'])
assert H('ECAI-MATH-PATH-V1',(cid(v1['domain']),cid(v2['codomain']),[(mid(m),1,['native bounded rational 2-torsion search']) for m in [v1,v2]]))=='5613D52AE7906E50112E3D08C03E86C2BC7E854BCE930E89148CD23975852D4E'
OUT.mkdir(parents=True,exist_ok=True)
for item in samples:
    raw=json.dumps(item['path'],ensure_ascii=False,separators=(',',':'))
    item['path_sha256']=hashlib.sha256(raw.encode()).hexdigest()
    item['file']=item['id']+'.json'
    (OUT/item['file']).write_text(raw,encoding='utf-8')
    item['path_json']=raw
catalog=dict(schema='ecai-math-samples/v1',default_id='doubling-6',samples=samples)
(OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
JS.write_text('// Generated by test/math_samples/generate_samples.py; do not hand-edit.\n'
              '// Bundled examples are NOT live node verification receipts.\n'
              'export const MATH_SAMPLES = '+json.dumps(catalog,ensure_ascii=False,separators=(',',':'))+';\n',encoding='utf-8')
print(json.dumps({'examples':len(samples),'accepted':len(samples)-1,'negative_controls':1,'maps_in_positive_examples':sum(i['path']['hops'] for i in samples[:-1]),'symbolic_checks':['[2] on n=6 via chord-and-tangent','[3] at j=0 via chord-and-tangent'],'known_native_id_checks':3},indent=2))
