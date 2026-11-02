/** OTV-001 ECAI console view: local 3D synthetic engineering challenge. */
import {
  OTV_SCENARIOS, OTV_RULES, simulateTransfer, evaluateTransfer,
  findReferencePatterns, makeEvidence, featureBlueprint
} from './ecai-orbital-model.js';

const EMPTY=Object.freeze({setVisible(){},dispose(){}});
const clamp=(n,a,b)=>Math.max(a,Math.min(b,n));
const text=(root,id,value)=>{const e=root.querySelector(`#${id}`);if(e)e.textContent=String(value);};
const css=(root,id,name,on)=>root.querySelector(`#${id}`)?.classList.toggle(name,on);

function project3D(p,w,h,camera){
  const [x,y,z]=p,cy=Math.cos(camera.yaw),sy=Math.sin(camera.yaw);
  const a=x*cy+z*sy,b=-x*sy+z*cy;
  const cp=Math.cos(camera.pitch),sp=Math.sin(camera.pitch);
  const y2=y*cp-b*sp,z2=y*sp+b*cp;
  const k=Math.min(w/12.2,h/7.4)*camera.zoom*9.5/(9.5-z2);
  return {x:w/2+a*k,y:h/2-y2*k,z:z2,k};
}
function sceneRenderer(canvas){
  const ctx=canvas.getContext('2d',{alpha:false});
  if(!ctx)return {draw(){},resize(){},orbit(){},zoom(){}};
  const camera={yaw:-0.31,pitch:0.18,zoom:1};
  let width=1080,height=600,dpr=1;
  function resize(){
    const r=canvas.getBoundingClientRect();if(r.width<1||r.height<1)return;
    width=r.width;height=r.height;dpr=Math.min(2,window.devicePixelRatio||1);
    const px=Math.round(width*dpr),py=Math.round(height*dpr);
    if(canvas.width!==px||canvas.height!==py){canvas.width=px;canvas.height=py;}
    ctx.setTransform(dpr,0,0,dpr,0,0);
  }
  function P(x,y,z){return project3D([x,y,z],width,height,camera);}
  function path(points,fill,stroke=null,lw=1){
    ctx.beginPath();for(let i=0;i<points.length;i++){const p=P(...points[i]);if(i===0)ctx.moveTo(p.x,p.y);else ctx.lineTo(p.x,p.y);}
    if(fill){ctx.closePath();ctx.fillStyle=fill;ctx.fill();}if(stroke){ctx.strokeStyle=stroke;ctx.lineWidth=lw;ctx.stroke();}
  }
  function circle(p,r,fill,blur=0){let q=P(...p);ctx.save();ctx.fillStyle=fill;ctx.shadowColor=fill;ctx.shadowBlur=blur;ctx.beginPath();ctx.arc(q.x,q.y,Math.max(1,r*q.k),0,Math.PI*2);ctx.fill();ctx.restore();}
  function line3(a,b,color,lw=1){path([a,b],null,color,lw);}
  function stars(){
    for(let i=0;i<114;i++){
      const u=((i*83+19)%131)/131,v=((i*71+31)%127)/127;
      const x=u*width,y=v*height;
      const alpha=.14+.42*((i*17)%13)/13;
      ctx.beginPath();ctx.fillStyle=`rgba(181,221,242,${alpha})`;ctx.arc(x,y,i%11===0?1.2:.65,0,Math.PI*2);ctx.fill();
    }
  }
  function renderTank(x,r,fraction,color,faces){
    const n=24,bottom=-1.22,top=1.25,fillY=bottom+(top-bottom)*clamp(fraction,0,1);
    const pt=(t,y)=>[x+Math.cos(t)*r,y,Math.sin(t)*r];
    for(let i=0;i<n;i++){
      const a=2*Math.PI*i/n,b=2*Math.PI*(i+1)/n;
      const middle=(a+b)/2;
      const light=.45+.32*Math.sin(middle+.75);
      faces.push({v:[pt(a,bottom),pt(b,bottom),pt(b,top),pt(a,top)],fill:`rgba(68,120,156,${.08+light*.09})`,stroke:'rgba(103,174,201,.15)',depth:P(...pt(middle,0)).z+.04});
      if(fillY>bottom){
        faces.push({v:[pt(a,bottom),pt(b,bottom),pt(b,fillY),pt(a,fillY)],fill:color==='cyan'?`rgba(65,216,232,${.27+light*.26})`:`rgba(246,183,91,${.25+light*.27})`,depth:P(...pt(middle,-.6)).z+.03});
      }
    }
    faces.push({v:Array.from({length:n},(_,i)=>pt(2*Math.PI*i/n,fillY)),fill:color==='cyan'?'rgba(103,243,243,.7)':'rgba(255,210,127,.7)',depth:P(x,fillY,0).z+.05});
    faces.push({v:Array.from({length:n},(_,i)=>pt(2*Math.PI*i/n,top)),fill:'rgba(35,76,102,.35)',depth:P(x,top,0).z+.07});
    return function finish(){
      for(const h of [bottom,top,fillY]){
        const points=Array.from({length:n+1},(_,i)=>pt(2*Math.PI*i/n,h));
        path(points,null,h===fillY?(color==='cyan'?'rgba(126,249,239,.66)':'rgba(255,213,142,.65)'):'rgba(109,183,208,.5)',h===fillY?2:1.4);
      }
      for(const theta of [0,Math.PI/2,Math.PI,Math.PI*1.5])line3(pt(theta,bottom),pt(theta,top),'rgba(150,211,232,.32)',1);
    };
  }
  function draw(sample,position){
    if(width<=0||height<=0)return;
    const bg=ctx.createRadialGradient(width*.52,height*.4,10,width*.52,height*.43,Math.max(width,height)*.66);
    bg.addColorStop(0,'#133248');bg.addColorStop(.56,'#081b2b');bg.addColorStop(1,'#04111d');ctx.fillStyle=bg;ctx.fillRect(0,0,width,height);
    stars();
    ctx.save();ctx.strokeStyle='rgba(49,132,173,.14)';ctx.lineWidth=1;
    for(let j=-5;j<=5;j++)line3([-5,-1.58,j*.65],[5,-1.58,j*.65],'rgba(73,143,179,.09)');
    for(let j=-8;j<=8;j++)line3([j*.65,-1.58,-3.25],[j*.65,-1.58,3.25],'rgba(73,143,179,.09)');
    ctx.restore();
    const faces=[];
    // Generic photovoltaic wings and bus structures, not actual spacecraft geometry.
    for(const sign of [-1,1]){
      const x=sign*3.75;
      for(let a=0;a<3;a++)for(let b=0;b<2;b++){
        const y=.07+(a-1)*.53,z=(b-.5)*.62;
        const verts=[[x,y-.235,z-.27],[x,y+.235,z-.27],[x,y+.235,z+.27],[x,y-.235,z+.27]];
        faces.push({v:verts,fill:'rgba(44,104,159,.5)',stroke:'rgba(95,190,215,.45)',depth:P(x,y,z).z});
      }
      line3([sign*2.9,0,0],[x,0,0],'rgba(113,193,206,.5)',3);
    }
    // Two translucent cylindrical test reservoirs.
    const sourceCap=112,receiverCap=36;
    const sourceFinish=renderTank(-2.25,.77,sample.source_mass/sourceCap,'cyan',faces);
    const receiverFinish=renderTank(2.25,.77,sample.receiver_mass/receiverCap,'amber',faces);
    faces.sort((a,b)=>a.depth-b.depth);
    for(const face of faces)path(face.v,face.fill,face.stroke||null,.7);
    // Opaque structural caps, transfer manifold and docking collar.
    sourceFinish();receiverFinish();
    for(const sx of [-2.25,2.25]){
      for(const yy of [-1.42,1.42]){
        const verts=Array.from({length:25},(_,i)=>[sx+Math.cos(i*Math.PI/12)*.81,yy,Math.sin(i*Math.PI/12)*.81]);
        path(verts,null,'rgba(150,224,233,.58)',2.3);
      }
    }
    line3([-1.48,-.64,0],[1.48,-.64,0],'rgba(45,117,154,.72)',17);
    line3([-1.48,-.64,0],[1.48,-.64,0],'rgba(153,209,225,.43)',7);
    circle([0,-.64,0],.24,'#355b77');circle([0,-.64,.16],.125,sample.command_open?'#75d8ce':'#dd8d70',6);
    if(sample.flow>.015){
      ctx.save();ctx.globalCompositeOperation='lighter';
      for(let i=0;i<10;i++){
        const at=((position*.26+i/10)%1);
        const x=-1.44+2.88*at;
        circle([x,-.64,.05+Math.sin(at*12+position*.1)*.035],i%3===0?.04:.025,i%3===0?'#b6fff4':'#77ddf5',11);
      }
      ctx.restore();
    }
    // Orbiting station markers and a third-dimensional bounding frame.
    const ring=[];for(let i=0;i<=90;i++){const a=i/90*Math.PI*2;ring.push([Math.cos(a)*4.6,-1.72,Math.sin(a)*2.95]);}
    path(ring,null,'rgba(89,174,194,.23)',1);
    const target=P(0,2.25,0);
    ctx.fillStyle='rgba(151,202,218,.65)';ctx.font='700 10px ui-monospace,monospace';ctx.textAlign='center';ctx.fillText('GENERIC COUPLED RESERVOIRS',target.x,target.y);
  }
  return {draw,resize,orbit(dx,dy){camera.yaw+=dx*.006;camera.pitch=clamp(camera.pitch+dy*.005,-1,1);},zoom(delta){camera.zoom=clamp(camera.zoom*(delta>0?.91:1.09),.62,1.65);},reset(){camera.yaw=-.31;camera.pitch=.18;camera.zoom=1;}};
}

function chartRenderer(canvas){
  const ctx=canvas.getContext('2d');if(!ctx)return ()=>{};
  return (samples,frame)=>{
    const rect=canvas.getBoundingClientRect();if(!rect.width||!rect.height)return;
    const ratio=Math.min(2,window.devicePixelRatio||1),w=rect.width,h=rect.height;
    canvas.width=Math.round(w*ratio);canvas.height=Math.round(h*ratio);
    ctx.setTransform(ratio,0,0,ratio,0,0);ctx.clearRect(0,0,w,h);
    const left=45,right=w-12,laneH=(h-28)/3;
    const lanes=[
      {field:'source_mass',label:'SOURCE',min:84,max:101,color:'#68dce6'},
      {field:'receiver_reported',label:'RECEIVER',min:11,max:28,color:'#e7bc77'},
      {field:'mass_residual',label:'RESIDUAL',min:0,max:1.7,color:'#f37f8c'}
    ];
    const x=i=>left+(right-left)*i/95;
    lanes.forEach((lane,j)=>{
      const top=5+j*laneH+9,bottom=5+(j+1)*laneH-11;
      const y=value=>bottom-clamp((value-lane.min)/(lane.max-lane.min),0,1)*(bottom-top);
      ctx.fillStyle='rgba(119,159,174,.63)';ctx.font='700 9px ui-monospace,monospace';ctx.textAlign='left';ctx.fillText(lane.label,4,top+2);
      ctx.strokeStyle='rgba(98,145,171,.17)';ctx.lineWidth=1;
      for(let t=0;t<5;t++){const yy=top+(bottom-top)*t/4;ctx.beginPath();ctx.moveTo(left,yy);ctx.lineTo(right,yy);ctx.stroke();}
      ctx.strokeStyle=lane.color;ctx.lineWidth=2;ctx.beginPath();samples.forEach((s,i)=>{const xx=x(i),yy=y(s[lane.field]);if(!i)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);});ctx.stroke();
      const p=samples[frame];ctx.fillStyle=lane.color;ctx.beginPath();ctx.arc(x(frame),y(p[lane.field]),3.5,0,Math.PI*2);ctx.fill();
    });
    const xp=x(frame);ctx.strokeStyle='rgba(230,244,244,.55)';ctx.setLineDash([4,4]);ctx.beginPath();ctx.moveTo(xp,4);ctx.lineTo(xp,h-10);ctx.stroke();ctx.setLineDash([]);
    ctx.fillStyle='rgba(154,183,194,.68)';ctx.font='10px ui-monospace,monospace';ctx.fillText('T+000',left,h-2);ctx.textAlign='right';ctx.fillText('T+095',right,h-2);
  };
}

function saveText(filename,content,type){
  const blob=new Blob([content],{type});const href=URL.createObjectURL(blob);
  const a=document.createElement('a');a.href=href;a.download=filename;document.body.append(a);a.click();a.remove();
  window.setTimeout(()=>URL.revokeObjectURL(href),2000);
}
const PITCH_TEXT=`Subject: SpaceX engineering challenge — reproducible orbital-transfer failures (OTV-001)

Hello Starship Engineering Team,

I'm Steven Joseph, founder of DamageBDD and developer of ECAI.

Rather than ask for proprietary data or pitch an untested aerospace AI claim, I've built OTV-001: an independently developed, public synthetic transfer-verification benchmark running inside the ECAI dashboard.

You can inject conservation, valve-command, thermal, pressure, sensor and event-order faults, inspect why each invariant fails, replay the full trace, and export SHA-256-bound evidence for an external verification process.

This is intentionally not a Starship fluid simulation or safety certification. ECAI native counterexample retrieval and DamageBDD cross-node execution are the next integration stages; the current public demo uses a local reference atlas and client-side verifier.

I intend to maintain ECAI and DamageBDD independently. I'm inviting SpaceX engineers to challenge the public benchmark using synthetic or published data, with no need for controlled spacecraft specifications.

Would an engineer in flight software verification or the propellant systems team be interested in breaking the first test cases?

Steven Joseph
https://damagebdd.com`;

export function initOrbitalVerification(){
  if(typeof document==='undefined')return EMPTY;
  const root=document.querySelector('#otvChallenge');if(!root)return EMPTY;
  const get=id=>root.querySelector(`#${id}`),canvas=get('otvScene'),chart=get('otvChart');
  const stage=sceneRenderer(canvas),chartDraw=chartRenderer(chart);
  let evaluated=null,evidence=null,frame=0,visible=false,playing=false,raf=0,last=0,wasDisposed=false;
  const handlers=[];const listen=(target,event,fn,opts)=>{target.addEventListener(event,fn,opts);handlers.push(()=>target.removeEventListener(event,fn,opts));};
  function renderFindings(){
    const box=get('otvFindings');box.replaceChildren();
    if(!evaluated)return;
    if(!evaluated.result.violations.length){const p=document.createElement('div');p.className='otv-finding is-pass';p.textContent='PASS · All six illustrative invariants held across 96 synthetic frames.';box.append(p);return;}
    for(const f of evaluated.result.violations){
      const item=document.createElement('div');item.className='otv-finding is-fail';
      const title=document.createElement('strong');title.textContent=`FAIL · ${f.name}`;
      const sub=document.createElement('p');sub.textContent=`First at T+${String(f.step).padStart(3,'0')} · observed ${f.observed} · benchmark bound ${f.bound}`;
      item.append(title,sub);box.append(item);
    }
    for(const rule of Object.keys(OTV_RULES).filter(k=>!evaluated.result.violations.some(x=>x.rule===k))){
      const item=document.createElement('div');item.className='otv-finding is-pass';item.textContent=`✓ ${OTV_RULES[rule].name}`;box.append(item);
    }
  }
  function renderAtlas(){
    const el=get('otvAnalogues');el.replaceChildren();
    const matches=findReferencePatterns(evaluated.result,2);
    if(!matches.length){el.textContent='No anomaly signature. Native ECAI index integration is pending.';return;}
    for(const m of matches){
      const item=document.createElement('div');item.className='otv-analogue';
      const match=document.createElement('span');match.className='otv-match';match.textContent=`${Math.round(m.similarity*100)}% pattern overlap`;
      const title=document.createElement('strong');title.textContent=`${m.id} · ${m.title}`;
      const note=document.createElement('p');note.textContent=m.hypothesis;
      item.append(match,title,note);el.append(item);
    }
  }
  function render(){
    if(!evaluated)return;
    const sample=evaluated.trace[frame];
    text(root,'otvSourceMass',sample.source_mass.toFixed(3));text(root,'otvReceiverMass',sample.receiver_reported.toFixed(3));
    text(root,'otvSceneValve',`COMMAND: ${sample.command_open?'OPEN':'CLOSED'} · FLOW: ${sample.flow.toFixed(3)}`);
    text(root,'otvFrameLabel',`T+${String(sample.step).padStart(3,'0')} / 095`);
    text(root,'otvSceneMode',evaluated.scenario.toUpperCase().replaceAll('-',' '));
    get('otvFrame').value=String(frame);
    if(visible){stage.draw(sample,frame);chartDraw(evaluated.trace,frame);}
  }
  async function build({autoplay=false}={}){
    playing=false;const scenario=get('otvScenario').value;const seed=Number(get('otvSeed').value);
    if(!Object.hasOwn(OTV_SCENARIOS,scenario)||!Number.isSafeInteger(seed)||seed<0||seed>999999999){
      text(root,'otvResultSummary','Enter an integer seed from 0 to 999999999.');return;
    }
    const local=evaluateTransfer(simulateTransfer({scenario,seed}));evaluated=local;
    const result=local.result;frame=autoplay?0:Math.max(0,local.trace.findIndex(s=>s.step===(result.first_violation_step??51)));
    text(root,'otvScenarioDescription',OTV_SCENARIOS[scenario].description);
    text(root,'otvChecks',String(result.checks).padStart(2,'0'));
    text(root,'otvFailures',String(result.failed_invariant_count).padStart(2,'0'));
    text(root,'otvFailuresNote',result.status==='PASS'?'No invariant violations':'Injected fault detected');
    text(root,'otvResidual',result.peak_mass_residual.toFixed(3));
    text(root,'otvFirstFault',result.first_violation_step===null?'NONE':`T+${String(result.first_violation_step).padStart(3,'0')}`);
    text(root,'otvSeedEvents',`${seed} / ${local.trace.length}`);
    text(root,'otvResultStatus',result.status);css(root,'otvResultStatus','is-fail',result.status==='FAIL');css(root,'otvResultStatus','is-pass',result.status==='PASS');
    text(root,'otvResultSummary',result.status==='PASS'?'No synthetic invariant violations across this fixture.':`${result.failed_invariant_count} of ${result.checks} rules flagged. The first violation is at T+${String(result.first_violation_step).padStart(3,'0')}.`);
    renderFindings();renderAtlas();render();
    text(root,'otvDigest','HASHING…');evidence=null;
    try{const receipt=await makeEvidence(local);if(evaluated===local){evidence=receipt;text(root,'otvDigest',`${receipt.sha256.slice(0,12)}…`);get('otvDigest').title=receipt.sha256;}}
    catch(e){if(evaluated===local)text(root,'otvDigest','HASH ERROR');}
    if(evaluated===local){playing=autoplay;text(root,'otvPause',playing?'Pause':'Play');}
  }
  function tick(ts){
    raf=0;if(wasDisposed||!visible||document.hidden)return;
    if(ts-last>=90){
      if(playing&&evaluated){frame=Math.min(95,frame+1);if(frame>=95){playing=false;text(root,'otvPause','Replay');}}
      stage.draw(evaluated.trace[frame],frame);if(evaluated&&playing)render();
      last=ts;
    }
    raf=requestAnimationFrame(tick);
  }
  function start(){if(!raf&&visible&&!document.hidden)raf=requestAnimationFrame(tick);}
  function stop(){if(raf)cancelAnimationFrame(raf);raf=0;}
  listen(get('otvRun'),'click',()=>{build({autoplay:true});start();});
  listen(get('otvScenario'),'change',()=>{build();start();});
  listen(get('otvSeed'),'change',()=>{build();start();});
  listen(get('otvPause'),'click',()=>{playing=!playing;if(playing&&frame===95)frame=0;text(root,'otvPause',playing?'Pause':'Play');start();});
  listen(get('otvFrame'),'input',e=>{playing=false;frame=clamp(Number(e.target.value),0,95);render();text(root,'otvPause','Play');});
  listen(get('otvExportEvidence'),'click',async()=>{
    if(!evaluated)return;
    if(!evidence)evidence=await makeEvidence(evaluated);
    saveText(`OTV-001-${evaluated.scenario}-${evaluated.seed}.evidence.json`,JSON.stringify({sha256:evidence.sha256,...evidence.evidence},null,2)+'\n','application/json');
  });
  listen(get('otvExportFeature'),'click',()=>{if(evaluated)saveText(`OTV-001-${evaluated.scenario}.feature`,featureBlueprint(evaluated.scenario,evaluated.seed),'text/plain');});
  listen(get('otvCopyPitch'),'click',async()=>{
    try{await navigator.clipboard.writeText(PITCH_TEXT);text(root,'otvCopyPitch','Copied pitch ✓');}
    catch{ text(root,'otvCopyPitch','Clipboard unavailable'); }
  });
  listen(get('otvPresent'),'click',async()=>{
    try{if(document.fullscreenElement)await document.exitFullscreen();else await root.requestFullscreen();}
    catch{ text(root,'otvPresent','Fullscreen unavailable'); }
    stage.resize();render();
  });
  listen(document,'fullscreenchange',()=>{text(root,'otvPresent',document.fullscreenElement?'Exit presentation':'Present challenge ↗');stage.resize();render();});
  let drag=null;
  listen(canvas,'pointerdown',e=>{drag={x:e.clientX,y:e.clientY,id:e.pointerId};canvas.setPointerCapture(e.pointerId);});
  listen(canvas,'pointermove',e=>{if(!drag||drag.id!==e.pointerId)return;stage.orbit(e.clientX-drag.x,e.clientY-drag.y);drag={...drag,x:e.clientX,y:e.clientY};render();});
  listen(canvas,'pointerup',()=>{drag=null;});listen(canvas,'pointercancel',()=>{drag=null;});
  listen(canvas,'wheel',e=>{e.preventDefault();stage.zoom(e.deltaY);render();},{passive:false});
  listen(canvas,'keydown',e=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();stage.orbit((e.key==='ArrowLeft'?18:e.key==='ArrowRight'?-18:0),(e.key==='ArrowUp'?16:e.key==='ArrowDown'?-16:0));render();});
  const resizeObserver=typeof ResizeObserver!=='undefined'?new ResizeObserver(()=>{if(visible){stage.resize();render();}}):null;
  resizeObserver?.observe(canvas);
  listen(document,'visibilitychange',()=>{if(document.hidden)stop();else start();});
  build();
  return {
    setVisible(on){visible=Boolean(on);if(visible){stage.resize();render();start();}else{playing=false;text(root,'otvPause','Play');stop();}},
    dispose(){wasDisposed=true;stop();resizeObserver?.disconnect();handlers.forEach(fn=>fn());}
  };
}
