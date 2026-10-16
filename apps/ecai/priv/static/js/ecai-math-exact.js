/* Bounded exact arithmetic for the local point/invariant workbench.
 * Point membership checks are not a proof that a rational map is an isogeny.
 * No server receipt, signature or discovery claim is produced here. */
const MAX_BITS = 4096;
function bounded(n) {
  if ((n < 0n ? -n : n).toString(2).length > MAX_BITS)
    throw new Error('Local arithmetic size limit reached. Use the exported path in SageMath.');
  return n;
}
function gcd(a,b) { a=a<0n?-a:a;b=b<0n?-b:b;while(b){[a,b]=[b,a%b];}return a; }
function q(n,d=1n) {
  bounded(n);bounded(d);if(d===0n)throw new Error('Zero rational denominator.');
  if(d<0n){n=-n;d=-d;}const g=gcd(n,d);return [n/g,d/g];
}
export function parseQ(v) {
  let parts;
  if(Array.isArray(v)) {
    if(v.length!==2)throw new Error('Expected an exact numerator/denominator pair.');
    parts=v.map(String);
  } else {
    const m=/^(-?\d+)(?:\/(\d+))?$/.exec(String(v).trim());
    if(!m)throw new Error('Enter an integer or fraction, not a decimal.');
    parts=[m[1],m[2]||'1'];
  }
  if(parts.some(s=>s.length>310||! /^-?\d+$/.test(s)))throw new Error('Rational input limit exceeded.');
  return q(BigInt(parts[0]),BigInt(parts[1]));
}
const add=(a,b)=>q(a[0]*b[1]+b[0]*a[1],a[1]*b[1]);
const neg=a=>[-a[0],a[1]];
const sub=(a,b)=>add(a,neg(b));
const mul=(a,b)=>q(a[0]*b[0],a[1]*b[1]);
const div=(a,b)=>q(a[0]*b[1],a[1]*b[0]);
const pow=(a,n)=>{let r=q(1n);for(let i=0;i<n;i++)r=mul(r,a);return r;};
const k=n=>q(BigInt(n));
const equal=(a,b)=>a[0]===b[0]&&a[1]===b[1];
export const formatQ=a=>a[1]===1n?String(a[0]):`${a[0]}/${a[1]}`;
const zero=a=>a[0]===0n;
function polyAt(cs,x) {
  if(!Array.isArray(cs)||cs.length>65)throw new Error('Polynomial size limit.');
  let a=k(0);for(let i=cs.length-1;i>=0;i--)a=add(mul(a,x),parseQ(cs[i]));return a;
}
function cubic(e,x) {return polyAt([e.a6,e.a4,e.a2,['1','1']],x);}
function onCurve(e,p){return p===null||equal(pow(p.y,2),cubic(e,p.x));}
function pointValue(p){return p===null?{infinity:true,x:null,y:null}:{infinity:false,x:formatQ(p.x),y:formatQ(p.y)};}
export function curveInvariants(e) {
  const a=parseQ(e.a2),b=parseQ(e.a4),c=parseQ(e.a6);
  const b2=mul(k(4),a), b4=mul(k(2),b), b6=mul(k(4),c);
  const b8=sub(mul(k(4),mul(a,c)),pow(b,2));
  const c4=sub(pow(b2,2),mul(k(24),b4));
  const c6=sub(add(neg(pow(b2,3)),mul(k(36),mul(b2,b4))),mul(k(216),b6));
  const delta=add(sub(sub(neg(mul(pow(b2,2),b8)),mul(k(8),pow(b4,3))),mul(k(27),pow(b6,2))),mul(k(9),mul(b2,mul(b4,b6))));
  if(zero(delta))throw new Error('Singular cubic: not an elliptic curve.');
  return {discriminant:formatQ(delta),j:formatQ(div(pow(c4,3),delta)),c4:formatQ(c4),c6:formatQ(c6)};
}
export function tracePoint(path,xText,yText,{infinity=false}={}) {
  if(!path||!Array.isArray(path.steps)||path.steps.length>16)throw new Error('Path size limit.');
  let p=infinity?null:{x:parseQ(xText),y:parseQ(yText)};
  if(!onCurve(path.source,p))throw new Error('The input point is not on the source curve.');
  const trace=[pointValue(p)];let current=path.source;
  for(const [i,step] of path.steps.entries()) {
    const m=step.map;
    if(!['a2','a4','a6'].every(k=>equal(parseQ(current[k]),parseQ(m.domain[k]))))throw new Error('Disconnected path.');
    if(p!==null) {
      const d=polyAt(m.x_den,p.x), l=polyAt(m.y_den,p.x);
      if(zero(d))p=null; // Valid isogeny poles map to O in this supported chart.
      else {
        if(zero(l))throw new Error(`Map ${i+1} needs projective evaluation.`);
        p={x:div(polyAt(m.x_num,p.x),d),y:mul(p.y,div(polyAt(m.y_num,p.x),l))};
      }
      if(!onCurve(m.codomain,p))throw new Error(`Map ${i+1}: the computed image is not on the target curve. Candidate rejected for this point.`);
    }
    current=m.codomain;trace.push(pointValue(p));
  }
  if(!['a2','a4','a6'].every(k=>equal(parseQ(current[k]),parseQ(path.target[k]))))throw new Error('Target mismatch.');
  return trace;
}
function addPoints(e,p,r) {
  if(p===null)return r;if(r===null)return p;
  let slope;
  if(equal(p.x,r.x)) {
    if(zero(add(p.y,r.y)))return null;
    slope=div(add(add(mul(k(3),pow(p.x,2)),mul(k(2),mul(parseQ(e.a2),p.x))),parseQ(e.a4)),mul(k(2),p.y));
  } else slope=div(sub(r.y,p.y),sub(r.x,p.x));
  const X=sub(sub(sub(pow(slope,2),parseQ(e.a2)),p.x),r.x);
  const Y=sub(mul(slope,sub(p.x,X)),p.y);
  return {x:X,y:Y};
}
export function scalarPoint(e,xText,yText,n) {
  if(!Number.isInteger(n)||n<1||n>16)throw new Error('Use a scalar from 1 to 16.');
  let p={x:parseQ(xText),y:parseQ(yText)},sum=null;
  if(!onCurve(e,p))throw new Error('The input point is not on the source curve.');
  for(let i=0;i<n;i++)sum=addPoints(e,sum,p);
  if(!onCurve(e,sum))throw new Error('Scalar result failed membership check.');
  return pointValue(sum);
}
export function sageScript(path) {
  // JSON-escaped string literal is also a valid Python str literal. No code from
  // labels, formulas or metadata is executed. Sage constructs polynomials as data.
  const text=JSON.stringify(JSON.stringify(path));
  return `# Save as ecai_check.py and run: sage -python ecai_check.py\n# Exact algebra check of the supplied candidate, not a provenance certificate.\nimport json\nfrom sage.all import QQ, PolynomialRing, EllipticCurve\np = json.loads(${text})\nR = PolynomialRing(QQ, 'x'); x = R.gen()\ndef q(v): return QQ(v[0])/QQ(v[1])\ndef E(c): return EllipticCurve(QQ, [0,q(c['a2']),0,q(c['a4']),q(c['a6'])])\ndef F(c): return x**3+q(c['a2'])*x**2+q(c['a4'])*x+q(c['a6'])\ndef P(v): return R([q(c) for c in v])\ncurrent = E(p['source']); degree = 1\nfor step in p['steps']:\n    m=step['map']; assert E(m['domain']) == current\n    N,D,M,L=[P(m[k]) for k in ('x_num','x_den','y_num','y_den')]\n    assert D != 0 and L != 0 and N.gcd(D).degree() == 0 and M.gcd(L).degree() == 0\n    assert N.degree()-D.degree() == 1 and M.degree() == L.degree()\n    assert max(N.degree(),D.degree()) == m['degree']\n    t=m['codomain']; current=E(t); assert current.discriminant() != 0\n    rhs=N**3+q(t['a2'])*N**2*D+q(t['a4'])*N*D**2+q(t['a6'])*D**3\n    assert F(m['domain'])*M**2*D**3 == rhs*L**2\n    degree *= m['degree']\nassert current == E(p['target']) and degree == int(p['total_degree'])\nprint('Exact map identities passed; composite degree:', degree)\n# This script does not check native ETF identifiers or authenticate source labels.\n`;
}

/* Display-only real locus. Approximation is deliberately kept outside exact
 * arithmetic and never used for membership, verification or badges. */
export function realCurvePlot(doc,e) {
  const host=doc.createElement('figure');host.className='math-real-plot';
  const caption=doc.createElement('figcaption');caption.textContent='Approximate real locus · illustration only';
  const cs=['a2','a4','a6'].map(k=>Number(e[k][0])/Number(e[k][1]));
  if(!cs.every(Number.isFinite)){host.append(caption);return host;}
  const [a,b,c]=cs,scale=Math.max(1,Math.abs(a),Math.sqrt(Math.abs(b)),Math.cbrt(Math.abs(c)));
  const xmin=-1.25*scale,xmax=2.1*scale,points=[];
  for(let i=0;i<=500;i++){const x=xmin+(xmax-xmin)*i/500;const v=((x+a)*x+b)*x+c;points.push({x,y:v>=0?Math.sqrt(v):null});}
  const ymax=Math.max(1,...points.map(p=>p.y||0))*1.08;
  if(!Number.isFinite(ymax)){host.append(caption);return host;}
  const ns='http://www.w3.org/2000/svg',svg=doc.createElementNS(ns,'svg');
  svg.setAttribute('viewBox','0 0 480 210');svg.setAttribute('role','img');svg.setAttribute('aria-label','Approximate real-coordinate curve, not evidence of rational points');
  const sx=x=>24+(x-xmin)/(xmax-xmin)*432,sy=y=>98-y/ymax*80;
  const line=(x1,y1,x2,y2)=>{const n=doc.createElementNS(ns,'line');for(const [k,v]of Object.entries({x1,y1,x2,y2}))n.setAttribute(k,String(v));n.setAttribute('class','math-real-axis');svg.append(n);};
  line(24,98,456,98);line(sx(0),12,sx(0),183);
  for(const sign of [1,-1]){let d='',pen=false;for(const p of points){if(p.y===null){pen=false;continue;}d+=`${pen?'L':'M'}${sx(p.x).toFixed(2)},${sy(sign*p.y).toFixed(2)} `;pen=true;}const n=doc.createElementNS(ns,'path');n.setAttribute('d',d);n.setAttribute('class','math-real-locus');svg.append(n);}
  for(const [px,text]of [[24,xmin.toPrecision(3)],[sx(0),'0'],[445,xmax.toPrecision(3)]]){const n=doc.createElementNS(ns,'text');n.setAttribute('x',String(px));n.setAttribute('y','203');n.setAttribute('text-anchor','middle');n.textContent=text;svg.append(n);}
  host.append(svg,caption);return host;
}
