/**
 * ECAI 3D geometric experiment lab. Deterministic, local and dependency-free.
 * These are floating-point embeddings of sampled points on E(R), NOT
 * algebraic isogenies, finite subgroup kernels, or verified semantic relations.
 * No network calls, signing, wallet access, or blockchain minting happen here.
 */
import {realOvalPoint} from './ecai-math-kernel.js';

const TAU = Math.PI * 2;
const MAX_Y = Math.sqrt(16 / (3 * Math.sqrt(3)));
const MATERIAL = Object.freeze({
  gold: [248,186,111], cyan: [85,211,221], blue: [105,153,238],
  violet: [170,135,230], body: [181,205,208], dark: [73,123,148],
  strand: [223,166,111]
});
const SHAPES = ['dragonfly', 'elliptic-torus', 'double-helix'];
const EMPTY = Object.freeze({setVisible() {}, dispose() {}});
const nice = n => Number(n).toFixed(6);
const V = (x,y,z) => [x,y,z];
const add = (a,b) => V(a[0]+b[0],a[1]+b[1],a[2]+b[2]);
const subtract = (a,b) => V(a[0]-b[0],a[1]-b[1],a[2]-b[2]);
const mul = (a,c) => V(a[0]*c,a[1]*c,a[2]*c);
const cross = (a,b) => V(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]);
const dot = (a,b) => a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
const norm = a => Math.hypot(...a);
const unit = a => mul(a,1/(norm(a)||1));
const clamp = (v,a,b) => Math.max(a,Math.min(b,v));

function face(mesh,a,b,c,material) {mesh.faces.push({a,b,c,material});}
function vertex(mesh,p) {mesh.vertices.push(p);return mesh.vertices.length-1;}
function grid(mesh,rows,cols,material,wrapRows=false,wrapCols=false) {
  const rowCount=wrapRows?rows.length:rows.length-1;
  const colCount=wrapCols?rows[0].length:rows[0].length-1;
  for(let i=0;i<rowCount;i++)for(let j=0;j<colCount;j++) {
    const p=rows[i][j],q=rows[(i+1)%rows.length][j];
    const r=rows[(i+1)%rows.length][(j+1)%rows[0].length],s=rows[i][(j+1)%rows[0].length];
    face(mesh,p,q,r,material);face(mesh,p,r,s,material);
  }
}
function ellipsoid(mesh,c,r,material,detail) {
  const lat=Math.max(7,Math.round(detail*.65)),lon=Math.max(10,detail);
  const rows=[];
  for(let i=0;i<=lat;i++) {
    const phi=Math.PI*i/lat,row=[];
    for(let j=0;j<lon;j++) {
      const theta=TAU*j/lon;
      row.push(vertex(mesh,V(c[0]+r[0]*Math.sin(phi)*Math.cos(theta),
                             c[1]+r[1]*Math.cos(phi),
                             c[2]+r[2]*Math.sin(phi)*Math.sin(theta))));
    }
    rows.push(row);
  }
  grid(mesh,rows,lon,material,false,true);
}
function tube(mesh,points,radius,material,radial=9,closed=false) {
  const rings=[];
  for(let i=0;i<points.length;i++) {
    const prev=points[closed?(i-1+points.length)%points.length:Math.max(0,i-1)];
    const next=points[closed?(i+1)%points.length:Math.min(points.length-1,i+1)];
    const tangent=unit(subtract(next,prev));
    const reference=Math.abs(dot(tangent,V(0,1,0)))>.95?V(0,0,1):V(0,1,0);
    const normal=unit(cross(tangent,reference)),binormal=unit(cross(tangent,normal));
    const ring=[];
    for(let j=0;j<radial;j++) {
      const a=TAU*j/radial, rr=typeof radius==='function'?radius(i/(points.length-1),j/radial):radius;
      ring.push(vertex(mesh,add(points[i],add(mul(normal,rr*Math.cos(a)),mul(binormal,rr*Math.sin(a))))));
    }
    rings.push(ring);
  }
  grid(mesh,rings,radial,material,closed,true);
  if(!closed){
    const start=vertex(mesh,points[0]),end=vertex(mesh,points.at(-1));
    for(let j=0;j<radial;j++){
      face(mesh,start,rings[0][(j+1)%radial],rings[0][j],material);
      face(mesh,end,rings.at(-1)[j],rings.at(-1)[(j+1)%radial],material);
    }
  }
}

/** One wing is a genuine 3D triangle sheet from the REAL Weierstrass oval profile. */
function wing(mesh,root,tip,width,detail,twist,material) {
  const along=subtract(tip,root),length=Math.hypot(along[0],along[1]);
  const side=V(-along[1]/length,along[0]/length,0),rowsTop=[],rowsBottom=[];
  const lateral=Math.max(6,Math.round(detail*.58));
  for(let i=0;i<=detail;i++) {
    const u=i/detail,x=-2*u;
    const y=Math.sqrt(Math.max(0,x*x*x-4*x));
    const profile=y/MAX_Y,rowTop=[],rowBottom=[];
    for(let j=0;j<=lateral;j++) {
      const v=2*j/lateral-1;
      const center=add(root,mul(along,u));
      const planar=add(center,mul(side,width*profile*v));
      const camber=.26*profile*(1-v*v)*Math.sin(Math.PI*u);
      const torsion=twist*.11*u*profile*v;
      const z=planar[2]+camber+torsion;
      rowTop.push(vertex(mesh,V(planar[0],planar[1],z+.012)));
      rowBottom.push(vertex(mesh,V(planar[0],planar[1],z-.012)));
    }
    rowsTop.push(rowTop);rowsBottom.push(rowBottom);
  }
  grid(mesh,rowsTop,lateral,material);
  for(let i=0;i<detail;i++)for(let j=0;j<lateral;j++) {
    const a=rowsBottom[i][j],b=rowsBottom[i+1][j],c=rowsBottom[i+1][j+1],d=rowsBottom[i][j+1];
    face(mesh,a,c,b,material);face(mesh,a,d,c,material);
  }
  for(let i=0;i<detail;i++)for(const sideJ of [0,lateral]) {
    const a=rowsTop[i][sideJ],b=rowsTop[i+1][sideJ],c=rowsBottom[i+1][sideJ],d=rowsBottom[i][sideJ];
    face(mesh,a,b,c,material);face(mesh,a,c,d,material);
  }
}
function makeDragonfly(mesh,detail,twist) {
  for(const sign of [-1,1]) {
    wing(mesh,V(sign*.12,-.22,0),V(sign*2.9,-1.23,sign*.34),.48,detail,twist,sign===1?'gold':'cyan');
    wing(mesh,V(sign*.12,.03,0),V(sign*2.75,1.11,-sign*.28),.52,detail,twist,sign===1?'violet':'blue');
  }
  ellipsoid(mesh,V(0,-.4,0),V(.29,.32,.29),'body',detail);
  ellipsoid(mesh,V(0,-.86,0),V(.24,.20,.23),'gold',detail);
  ellipsoid(mesh,V(-.13,-.91,-.12),V(.095,.075,.075),'dark',12);
  ellipsoid(mesh,V(.13,-.91,-.12),V(.095,.075,.075),'dark',12);
  const tail=Array.from({length:28},(_,i)=>V(.05*Math.sin(i*.45),-.12+i*.092,.075*Math.sin(i*.34)));
  tube(mesh,tail,t=>.15*(1-.76*t)+.024*Math.sin(t*7*TAU)**2,'body',10);
  for(const sign of [-1,1])tube(mesh,Array.from({length:9},(_,i)=>V(sign*(.14+.17*i/8),-.96-.22*i/8,.02+.09*Math.sin(i/8*Math.PI)) ),.016,'dark',5);
}

function oval3D(t,twist) {
  const {x,y}=realOvalPoint(t);
  return V((x+1)*2.15,(y/MAX_Y)*1.63,.21*Math.sin(3*t)*twist);
}
function makeTorus(mesh,detail,twist) {
  const n=detail*8,radial=Math.max(8,Math.floor(detail/2));
  const points=Array.from({length:n},(_,i)=>oval3D(Math.PI+TAU*i/n,twist));
  const rings=[];
  for(let i=0;i<n;i++) {
    const t=TAU*i/n,prev=points[(i-1+n)%n],next=points[(i+1)%n];
    const tangent=unit(subtract(next,prev));
    const normal=unit(cross(tangent,V(0,0,1)));
    const binormal=unit(cross(tangent,normal)),row=[];
    const rr=.28+.11*Math.cos(t*4);
    for(let j=0;j<radial;j++) {
      const phi=TAU*j/radial+twist*t,point=add(points[i],add(mul(normal,rr*Math.cos(phi)),mul(binormal,rr*Math.sin(phi))));
      row.push(vertex(mesh,point));
    }
    rings.push(row);
  }
  grid(mesh,rings,radial,'cyan',true,true);
  for(let s=0;s<3;s++) {
    const guide=Array.from({length:n+1},(_,i)=>{
      const t=TAU*i/n,p=oval3D(Math.PI+t,twist);
      return add(p,V(.13*Math.cos(3*t+TAU*s/3),.13*Math.sin(3*t+TAU*s/3),.18*Math.sin(3*t+TAU*s/3)));
    });
    tube(mesh,guide,.018,['gold','violet','blue'][s],5);
  }
}
function makeHelix(mesh,detail,twist) {
  const count=detail*9,turns=2+twist*.55;
  for(const side of [0,1]) {
    const points=Array.from({length:count},(_,i)=>{
      const u=i/(count-1),curve=realOvalPoint(Math.PI+TAU*u);
      const radius=1+.20*(curve.x+1);
      const phase=turns*TAU*u+Math.PI*side;
      return V(radius*Math.cos(phase),3.7*(u-.5),radius*Math.sin(phase));
    });
    tube(mesh,points,.095,side?'gold':'cyan',10);
  }
  const bridges=Math.max(8,Math.round(detail*.8));
  for(let i=0;i<=bridges;i++) {
    const u=i/bridges,curve=realOvalPoint(Math.PI+TAU*u),radius=1+.20*(curve.x+1),phase=turns*TAU*u;
    tube(mesh,[V(radius*Math.cos(phase),3.7*(u-.5),radius*Math.sin(phase)),V(-radius*Math.cos(phase),3.7*(u-.5),-radius*Math.sin(phase))],.026,'violet',5);
  }
}

export function generate3DMesh({shape='dragonfly',detail=22,twist=1}={}) {
  if(!SHAPES.includes(shape))throw Error('Unsupported 3D model');
  if(!Number.isInteger(detail)||detail<10||detail>40)throw Error('Detail must be 10–40');
  if(!Number.isFinite(twist)||twist<0||twist>5)throw Error('Twist must be 0–5');
  const mesh={vertices:[],faces:[],shape};
  if(shape==='dragonfly')makeDragonfly(mesh,detail,twist);
  else if(shape==='elliptic-torus')makeTorus(mesh,detail,twist);
  else makeHelix(mesh,detail,twist);
  return mesh;
}

export function meshToOBJ(mesh) {
  const output=['# ECAI visual geometry experiment · not an isogeny proof','o ecai_elliptic_'+mesh.shape.replaceAll('-','_')];
  for(const [x,y,z] of mesh.vertices)output.push(`v ${nice(x)} ${nice(y)} ${nice(z)}`);
  let last='';
  for(const f of mesh.faces) {
    if(f.material!==last){output.push('g '+f.material);last=f.material;}
    output.push(`f ${f.a+1} ${f.b+1} ${f.c+1}`);
  }
  return output.join('\n')+'\n';
}
/** FIPS 180-4 SHA-256 fallback for file:// and non-secure, offline previews. */
export function sha256Fallback(text) {
  const input=new TextEncoder().encode(text),length=input.length;
  const blocks=new Uint8Array(Math.ceil((length+9)/64)*64);
  blocks.set(input);blocks[length]=0x80;
  const high=Math.floor(length/0x20000000),low=(length*8)>>>0;
  const last=blocks.length-8;
  for(let i=0;i<4;i++){blocks[last+i]=(high>>>((3-i)*8))&255;blocks[last+4+i]=(low>>>((3-i)*8))&255;}
  const K=('428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5 '+
    'd807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174 '+
    'e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da '+
    '983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967 '+
    '27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85 '+
    'a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070 '+
    '19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3 '+
    '748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2')
    .split(' ').map(v=>parseInt(v,16));
  const H=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                           0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);
  const w=new Uint32Array(64),rotr=(x,n)=>(x>>>n)|(x<<(32-n));
  for(let pos=0;pos<blocks.length;pos+=64) {
    for(let t=0;t<16;t++){const o=pos+t*4;w[t]=((blocks[o]<<24)|(blocks[o+1]<<16)|(blocks[o+2]<<8)|blocks[o+3])>>>0;}
    for(let t=16;t<64;t++){
      const a=w[t-15],b=w[t-2];
      const s0=rotr(a,7)^rotr(a,18)^(a>>>3),s1=rotr(b,17)^rotr(b,19)^(b>>>10);
      w[t]=(w[t-16]+s0+w[t-7]+s1)>>>0;
    }
    let [a,b,c,d,e,f,g,h]=H;
    for(let t=0;t<64;t++) {
      const s1=rotr(e,6)^rotr(e,11)^rotr(e,25),ch=(e&f)^((~e)&g);
      const temp1=(h+s1+ch+K[t]+w[t])>>>0;
      const s0=rotr(a,2)^rotr(a,13)^rotr(a,22),maj=(a&b)^(a&c)^(b&c);
      const temp2=(s0+maj)>>>0;
      h=g;g=f;f=e;e=(d+temp1)>>>0;d=c;c=b;b=a;a=(temp1+temp2)>>>0;
    }
    for(const [i,val] of [a,b,c,d,e,f,g,h].entries())H[i]=(H[i]+val)>>>0;
  }
  return Array.from(H,x=>x.toString(16).padStart(8,'0')).join('');
}

export async function sha256Hex(text) {
  if(!globalThis.crypto?.subtle)return sha256Fallback(text);
  const result=await globalThis.crypto.subtle.digest('SHA-256',new TextEncoder().encode(text));
  return Array.from(new Uint8Array(result),x=>x.toString(16).padStart(2,'0')).join('');
}

/** Public reproducibility manifest, scoped honestly to visual geometry only. */
export async function experimentBundle(config,mesh=generate3DMesh(config)) {
  const obj=meshToOBJ(mesh),objSha256=await sha256Hex(obj);
  const parameters={shape:config.shape,detail:config.detail,twist:config.twist};
  const claim={
    schema:'ecai.geometry-experiment.v1',
    source_curve:{field:'real floating-point',model:'short Weierstrass',equation:'y^2 = x^3 - 4x',a4:-4,a6:0},
    generator:{name:'ecai-math-3d',version:'1.0.0',method:'deterministic parametric lift of sampled real-curve geometry'},
    parameters,
    mesh:{format:'Wavefront OBJ',vertex_count:mesh.vertices.length,triangle_count:mesh.faces.length,sha256:objSha256},
    verification:{source_curve_sampled_numerically:true,exact_isogeny:false,semantic_relation:false,damagebdd_report:null},
    provenance:{execution:'local browser',network_requests:0,blockchain_transactions:0}
  };
  const id=await sha256Hex(JSON.stringify(claim));
  const receipt={experiment_id:'sha256:'+id,...claim};
  const title=SHAPES.indexOf(config.shape)+1+' · '+config.shape.replaceAll('-',' ');
  const metadata={
    name:'ECAI visual experiment '+title,
    description:'A reproducible floating-point 3D geometry experiment derived from sampled real Weierstrass-curve points. It does not prove an isogeny or a semantic relation.',
    media_type:'3D_OBJ',
    media_url:'ipfs://REPLACE_WITH_PINNED_OBJ_CID',
    traits:{experiment_sha256:id,mesh_sha256:objSha256,source_curve:'y^2=x^3-4x',generator:'ecai-math-3d/1.0.0',shape:config.shape,exact_isogeny:false},
    experiment_manifest_uri:'ipfs://REPLACE_WITH_PINNED_MANIFEST_CID'
  };
  return {obj,receipt,metadata};
}

function rotation(point,yaw,pitch) {
  const [x,y,z]=point,c=Math.cos(yaw),s=Math.sin(yaw);
  const xx=x*c+z*s,zz=z*c-x*s,cp=Math.cos(pitch),sp=Math.sin(pitch);
  return V(xx,y*cp-zz*sp,y*sp+zz*cp);
}
function projection(point,yaw,pitch,distance,width,height) {
  const p=rotation(point,yaw,pitch),scale=Math.min(width,height)*.56*distance/(distance+p[2]);
  return {x:width/2+p[0]*scale/3.5,y:height/2-p[1]*scale/3.5,z:p[2]};
}
function download(name,content,type) {
  const url=URL.createObjectURL(new Blob([content],{type}));
  const a=document.createElement('a');a.href=url;a.download=name;document.body.append(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),10000);
}
function renderMesh(canvas,mesh,state) {
  const ctx=canvas.getContext('2d');if(!ctx)return;
  const rect=canvas.getBoundingClientRect(),w=rect.width,h=rect.height;
  if(!w||!h)return;
  const dpr=Math.min(2,window.devicePixelRatio||1);
  const pw=Math.round(w*dpr),ph=Math.round(h*dpr);
  if(canvas.width!==pw||canvas.height!==ph){canvas.width=pw;canvas.height=ph;}
  ctx.setTransform(dpr,0,0,dpr,0,0);
  const grad=ctx.createRadialGradient(w*.48,h*.45,4,w*.5,h*.5,w*.7);
  grad.addColorStop(0,'#133044');grad.addColorStop(1,'#07111d');ctx.fillStyle=grad;ctx.fillRect(0,0,w,h);
  ctx.strokeStyle='rgba(112,169,196,.11)';ctx.lineWidth=1;
  for(let x=0;x<w;x+=46){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke();}
  for(let y=0;y<h;y+=46){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke();}
  const projected=mesh.vertices.map(v=>projection(v,state.yaw,state.pitch,state.distance,w,h));
  const faces=mesh.faces.map(f=>({face:f,depth:(projected[f.a].z+projected[f.b].z+projected[f.c].z)/3}));
  faces.sort((a,b)=>b.depth-a.depth);
  for(const {face:f} of faces) {
    const a=projected[f.a],b=projected[f.b],c=projected[f.c];
    const p=rotation(mesh.vertices[f.a],state.yaw,state.pitch),q=rotation(mesh.vertices[f.b],state.yaw,state.pitch),r=rotation(mesh.vertices[f.c],state.yaw,state.pitch);
    const normal=unit(cross(subtract(q,p),subtract(r,p))),light=clamp(.42+.65*Math.abs(dot(normal,unit(V(.4,-.55,.8)))),.23,1);
    const base=MATERIAL[f.material]||MATERIAL.cyan;
    ctx.fillStyle='rgb('+base.map(v=>Math.round(v*light)).join(',')+')';
    ctx.beginPath();ctx.moveTo(a.x,a.y);ctx.lineTo(b.x,b.y);ctx.lineTo(c.x,c.y);ctx.closePath();ctx.fill();
    if(state.edges){ctx.strokeStyle='rgba(9,28,42,.35)';ctx.lineWidth=.5;ctx.stroke();}
  }
  ctx.textBaseline='top';ctx.font='11px ui-monospace, monospace';ctx.fillStyle='#b0c9d9';
  ctx.fillText('ECAI · E(ℝ) → MESH3D',17,17);
  ctx.fillStyle='#7fa1ae';ctx.fillText('DRAG ROTATE  ·  WHEEL ZOOM',17,h-28);
}

export function initMath3D() {
  if(typeof document==='undefined')return EMPTY;
  const root=document.getElementById('math3DWorkbench');if(!root)return EMPTY;
  const $=id=>root.querySelector('#'+id);
  const canvas=$('math3DStage'),shape=$('math3DShape'),detail=$('math3DDetail'),twist=$('math3DTwist');
  if(!canvas?.getContext('2d'))return EMPTY;
  const abort=new AbortController(),signal=abort.signal;
  let disposed=false,visible=false,onscreen=true,playing=!window.matchMedia?.('(prefers-reduced-motion:reduce)').matches;
  let raf=0,last=0,mesh,claim=null,pending=0,drag=null;
  const state={yaw:.58,pitch:-.32,distance:10,edges:true};
  function config(){return {shape:shape.value,detail:Number(detail.value),twist:Number(twist.value)};}
  function draw(){if(!visible||disposed||!mesh)return;renderMesh(canvas,mesh,state);}
  function resetReceipt(){pending++;claim=null;$('math3DReceipt').hidden=true;$('math3DStatus').textContent='Local geometry preview · not minted';}
  function remake(){try {mesh=generate3DMesh(config());$('math3DVertices').textContent=mesh.vertices.length.toLocaleString();$('math3DFaces').textContent=mesh.faces.length.toLocaleString();$('math3DDetailLabel').textContent=detail.value;$('math3DTwistLabel').textContent=twist.value;resetReceipt();draw();}catch(error){$('math3DStatus').textContent=error.message;}}
  function animate(t){raf=0;if(!visible||!playing||!onscreen||document.hidden||disposed)return;
    const dt=Math.min((t-(last||t))/1000,.06);last=t;state.yaw+=dt*.18;draw();raf=requestAnimationFrame(animate);}
  function sync(){const active=visible&&playing&&onscreen&&!document.hidden&&!disposed;
    $('math3DPlay').textContent=playing?'Pause rotation':'Auto rotate';$('math3DPlay').setAttribute('aria-pressed',String(playing));
    root.dataset.animating=String(active);if(!active){if(raf)cancelAnimationFrame(raf);raf=0;last=0;}else if(!raf){last=0;raf=requestAnimationFrame(animate);}}
  for(const control of [shape,detail,twist])control.addEventListener('input',remake,{signal});
  $('math3DEdges').addEventListener('change',()=>{state.edges=$('math3DEdges').checked;draw();},{signal});
  $('math3DPlay').addEventListener('click',()=>{playing=!playing;sync();},{signal});
  $('math3DReset').addEventListener('click',()=>{state.yaw=.58;state.pitch=-.32;state.distance=10;draw();},{signal});
  canvas.addEventListener('pointerdown',event=>{drag={x:event.clientX,y:event.clientY};canvas.setPointerCapture(event.pointerId);},{signal});
  canvas.addEventListener('pointermove',event=>{if(!drag)return;state.yaw+=(event.clientX-drag.x)*.009;state.pitch=clamp(state.pitch+(event.clientY-drag.y)*.009,-1.4,1.4);drag={x:event.clientX,y:event.clientY};draw();},{signal});
  for(const name of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,()=>{drag=null;},{signal});
  canvas.addEventListener('wheel',event=>{event.preventDefault();state.distance=clamp(state.distance+Math.sign(event.deltaY)*.8,6,19);draw();},{signal,passive:false});
  canvas.addEventListener('keydown',event=>{const key=event.key;if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(key))return;event.preventDefault();if(key==='ArrowLeft')state.yaw-=.15;if(key==='ArrowRight')state.yaw+=.15;if(key==='ArrowUp')state.pitch=clamp(state.pitch-.15,-1.4,1.4);if(key==='ArrowDown')state.pitch=clamp(state.pitch+.15,-1.4,1.4);draw();},{signal});
  async function prepare(){const seq=++pending;$('math3DStatus').textContent='Hashing the reproducible mesh…';$('math3DPrepare').disabled=true;
    try {const bundle=await experimentBundle(config(),mesh);if(seq!==pending||disposed)return;
      claim=bundle;$('math3DReceipt').hidden=false;$('math3DExperimentId').textContent=bundle.receipt.experiment_id;
      $('math3DMeshHash').textContent=bundle.receipt.mesh.sha256;
      $('math3DStatus').textContent='Reproducible local artifact prepared · no upload or mint transaction';
      $('math3DReceipt').scrollIntoView({block:'nearest',behavior:'smooth'});
    } catch(error){$('math3DStatus').textContent=error.message;}finally{$('math3DPrepare').disabled=false;}}
  $('math3DPrepare').addEventListener('click',()=>void prepare(),{signal});
  $('math3DExportOBJ').addEventListener('click',()=>{if(claim)download('ecai-'+shape.value+'.obj',claim.obj,'text/plain');},{signal});
  $('math3DExportJSON').addEventListener('click',()=>{if(claim)download('ecai-'+shape.value+'-experiment.json',JSON.stringify(claim.receipt,null,2)+'\n','application/json');},{signal});
  $('math3DExportNFT').addEventListener('click',()=>{if(claim)download('ecai-'+shape.value+'-aex141-metadata-template.json',JSON.stringify(claim.metadata,null,2)+'\n','application/json');},{signal});
  $('math3DExportPNG').addEventListener('click',()=>{if(!claim)return;try{const a=document.createElement('a');a.download='ecai-'+shape.value+'.png';a.href=canvas.toDataURL('image/png');document.body.append(a);a.click();a.remove();}catch(error){$('math3DStatus').textContent=error.message;}},{signal});
  const intersection=typeof IntersectionObserver==='function'?new IntersectionObserver(items=>{onscreen=Boolean(items[0]?.isIntersecting);sync();},{threshold:0}):null;
  intersection?.observe(root);
  const resize=typeof ResizeObserver==='function'?new ResizeObserver(draw):null;resize?.observe(canvas);
  document.addEventListener('visibilitychange',sync,{signal});
  window.addEventListener('resize',draw,{signal});
  remake();
  return {setVisible(value){if(disposed)return;visible=Boolean(value);draw();sync();},dispose(){if(disposed)return;disposed=true;sync();abort.abort();resize?.disconnect();intersection?.disconnect();}};
}
