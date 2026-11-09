import {SCENARIOS,DEFAULTS,runScenario,trips,recordAt,fixture,validatePlan,canonical,makeEvidence,runReferenceSuite} from './food-rescue-model.js?v=food-rescue-v1';
const empty=()=>({setVisible(){},refresh(){},dispose(){}});
const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const clock=minute=>`${String(9+Math.floor(minute/60)).padStart(2,'0')}:${String(minute%60).padStart(2,'0')}`;
const labels={'available':'At the hub','in-transit':'In transit','delivered':'Eligible delivery','quarantined':'Quarantined','recall-hold':'Recipient recall hold','unverifiable':'Unverifiable','unallocated':'Not allocated'};
const colour=state=>state==='delivered'?'#b1ed79':state==='in-transit'?'#66d3ce':['quarantined','recall-hold'].includes(state)?'#ffaaaa':state==='unverifiable'?'#f3c97b':'#9db7ab';
const TOUR=[
 ['Start with one morning','400 kg of fictional food is waiting at a hub. Choose a disruption or adjust van capacity and delay. Every scenario is public and runs on your device.'],
 ['Compare decisions, not promises','The simple plan dispatches by expiry and earliest arrival. The rescue plan searches this bounded timetable. Both use the same safety rules. Matching outcomes are shown honestly.'],
 ['Follow each lot','Play the map or drag the clock. Open a lot to inspect its sensor fixture. Click a recipient to filter the stock. A recall after delivery creates a recipient hold and removes that stock from rescued totals.'],
 ['Challenge and verify','Try releasing a recalled lot, run all eight scenarios, or export evidence. The Python verifier independently reconstructs the synthetic run. Local checks are not a remote DamageBDD run or real food-safety certification.']
];
export function initFoodRescue(options={}) {
  if(typeof document==='undefined')return empty();const root=document.getElementById('foodRescue');if(!root)return empty();
  const q=name=>root.querySelector(`[data-fr="${name}"]`);
  let scenario='everyday',result=null,previous=null,path='rescue',minute=0,filter=null,visible=!!options.visible,disposed=false,timer=null,revision=0,tourIndex=0;
  const listeners=[];const on=(el,event,fn)=>{el.addEventListener(event,fn);listeners.push(()=>el.removeEventListener(event,fn));};
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const controls=()=>({capacityKg:Number(q('capacity').value),delayMinutes:Number(q('delay').value)});
  const put=(name,text)=>{q(name).textContent=text;};
  const message=text=>put('message',text);
  const execution=()=>result?.[path];
  function stop(){if(timer!==null)clearInterval(timer);timer=null;root.dataset.playing='false';put('play','▶ Play');q('play').setAttribute('aria-pressed','false');}
  function invalidate(){
    stop();revision++;if(result)previous=result;result=null;root.dataset.stale='true';q('results').dataset.stale='true';q('stale').hidden=false;
    for(const name of ['rescued','uplift','held','unmet','pass'])put(name,'—');
    for(const name of ['export','play','next','position','path'])q(name).disabled=true;
    put('capacity-label',controls().capacityKg+' kg');put('challenge-result','');message('Inputs changed. Compare again before using or exporting a result.');
  }
  function selectScenario(id){scenario=id;q('capacity').value=String(DEFAULTS.capacityKg);q('delay').value=String(DEFAULTS.delayMinutes);run();}
  function run(){
    stop();revision++;filter=null;minute=0;
    try {
      result=runScenario(scenario,controls());previous=result;
      q('results').dataset.stale='false';root.dataset.stale='false';q('stale').hidden=true;
      for(const name of ['export','play','next','position','path'])q(name).disabled=false;
      put('capacity-label',controls().capacityKg+' kg');put('challenge-result','');
      root.querySelectorAll('[data-fr-scenario]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.frScenario===scenario)));
      renderSummary();renderFrame();
      message(`Comparison ready. ${result.rescue.plan.searchNodes} search states checked. Press Play or inspect a lot. Synthetic results only.`);
    }catch(error){invalidate();message('Unable to run: '+error.message);}
  }
  function renderSummary(){
    if(!result)return;const {world,rescue,baseline}=result,m=rescue.metrics;
    put('rescued',m.rescuedKg+' kg');put('total','of '+m.totalKg+' kg in the fixture');
    const difference=m.rescuedKg-baseline.metrics.rescuedKg;put('uplift',(difference>=0?'+':'')+difference+' kg');
    put('held',m.quarantineKg+' / '+m.unverifiableKg+' kg');
    put('held-note',m.recipientHoldKg?`${m.recipientHoldKg} kg placed on hold at recipients.`:'Held is not rescued; unknown is not a pass.');put('unmet',m.unmetKg+' kg');
    q('comparison').innerHTML=[['Simple expiry-first dispatch',baseline],['Rescue plan · bounded exact',rescue]].map(([title,e])=>`<div class="fr-comparison-row"><div><span>${title}</span><strong>${e.metrics.rescuedKg} kg</strong></div><div class="fr-comparison-bar" aria-label="${escape(title)}: ${e.metrics.rescuedKg} kg eligible"><span style="width:${e.metrics.rescuedKg/m.totalKg*100}%"></span><span class="fr-held-fill" style="width:${e.metrics.quarantineKg/m.totalKg*100}%"></span><span class="fr-unknown-fill" style="width:${e.metrics.unverifiableKg/m.totalKg*100}%"></span></div><small>${e.metrics.quarantineKg} kg held · ${e.metrics.unverifiableKg} kg unverifiable · ${e.metrics.unallocatedKg} kg unallocated</small></div>`).join('');
    q('timetable').innerHTML=trips(world).map(t=>`<tr><td>${t.id}</td><td>${t.vehicle}${world.vehicles.find(v=>v.id===t.vehicle).available?'':' · offline'}</td><td>${escape(world.destinations.find(d=>d.id===t.destination).name)}</td><td>${clock(t.depart)}</td><td>${t.arrival===null?'No route':clock(t.arrival)}</td><td>${t.returns===null?'—':clock(t.returns)}</td></tr>`).join('');
  }
  function pointOnTrip(world,trip,time){
    const nodes=trip.route.nodes,returning=time>trip.arrival;
    let elapsed=returning?trip.returns-time:time-trip.depart;
    for(let i=0;i<nodes.length-1;i++){
      const a=world.nodes.find(n=>n.id===nodes[i]),b=world.nodes.find(n=>n.id===nodes[i+1]);
      const edge=world.edges.find(e=>(e.a===a.id&&e.b===b.id)||(e.a===b.id&&e.b===a.id));
      if(elapsed<=edge.minutes){const t=Math.max(0,Math.min(1,elapsed/edge.minutes));return{x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t,returning};}
      elapsed-=edge.minutes;
    }return {...world.nodes.find(n=>n.id===nodes.at(-1)),returning};
  }
  function drawMap(records){
    const world=result.world,e=execution(),ts=trips(world),node=id=>world.nodes.find(n=>n.id===id);
    const roads=world.edges.map(edge=>{const a=node(edge.a),b=node(edge.b);return `<path class="fr-road ${world.closedEdges.includes(edge.id)?'fr-road-closed':''}" d="M${a.x} ${a.y}L${b.x} ${b.y}"/>`;}).join('');
    const routeLines=ts.filter(t=>e.plan.assignments.some(a=>a.trip===t.id)&&t.route).map(t=>`<polyline class="fr-road-active" points="${t.route.nodes.map(id=>node(id).x+','+node(id).y).join(' ')}"/>`).join('');
    const places=['depot',...world.destinations.map(d=>d.id)].map(id=>{
      const n=node(id),rs=records.filter(r=>r.location===id),kg=rs.filter(r=>r.state==='delivered').reduce((s,r)=>s+r.kg,0),held=rs.filter(r=>['quarantined','recall-hold','unverifiable'].includes(r.state)).reduce((s,r)=>s+r.kg,0);
      const fill=id==='depot'?'#244035':'#163331',label=id==='depot'?rs.reduce((s,r)=>s+r.kg,0)+' kg at hub':kg+' kg delivered';
      return `<g class="fr-map-node" data-fr-node="${id}" data-selected="${filter===id}" tabindex="0" role="button" aria-label="${escape(n.name+', '+label+', '+held+' kg held; show lots')}" transform="translate(${n.x} ${n.y})"><rect x="-32" y="-24" width="64" height="48" rx="12" fill="${fill}" stroke="${held?'#c38379':'#4a7361'}" stroke-width="1.5"/>${id==='depot'?'<path d="M-19 9V-6L0-16 19-6V9ZM-10 9V-1H10V9" fill="none" stroke="#b1ed79" stroke-width="2"/>':'<path d="M-16 12V-14H16V12ZM-7-7H-2M5-7H10M-7 0H-2M5 0H10M-4 12V6H4V12" fill="none" stroke="#b1ed79" stroke-width="2"/>'}<text text-anchor="middle" y="43" class="fr-map-label">${escape(n.name)}</text><text text-anchor="middle" y="59" class="fr-map-small">${label}</text>${held?`<text text-anchor="middle" y="75" fill="#ffaaaa" font-size="10">${held} kg held / unknown</text>`:''}</g>`;
    }).join('');
    const vans=ts.filter(t=>minute>=t.depart&&minute<t.returns&&e.ledger.some(l=>l.action==='loaded'&&l.at===t.depart&&e.plan.assignments.some(a=>a.lot===l.lot&&a.trip===t.id))).map(t=>{
      const p=pointOnTrip(world,t,minute),kg=e.ledger.filter(l=>l.action==='loaded'&&l.at===t.depart&&e.plan.assignments.some(a=>a.lot===l.lot&&a.trip===t.id)).reduce((s,l)=>s+l.kg,0);
      const offset=t.vehicle==='VAN-A'?-10:10;
      return `<g transform="translate(${p.x} ${p.y+offset})"><rect x="-20" y="-12" width="40" height="24" rx="6" fill="${t.vehicle==='VAN-A'?'#b1ed79':'#66d3ce'}" stroke="#0a1718" stroke-width="2"/><path d="M-11-5H3V6H-11ZM7-4H12L15 1H7Z" fill="#254436"/><circle cx="-10" cy="11" r="4" fill="#0a1718"/><circle cx="11" cy="11" r="4" fill="#0a1718"/><rect x="-31" y="-32" width="62" height="16" rx="4" fill="#0a1718"/><text y="-21" text-anchor="middle" fill="#e9f2e9" font-size="9">${t.vehicle.at(-1)} · ${p.returning?'return':kg+' kg'}</text></g>`;
    }).join('');
    q('map').innerHTML=`<svg class="fr-map" viewBox="0 0 790 480" role="img" aria-labelledby="frMapTitle frMapDesc"><title id="frMapTitle">Food rescue route replay at ${clock(minute)}</title><desc id="frMapDesc">Fictional hub, three recipients, two vans and a river crossing. ${world.closedEdges.length?'The bridge is closed; routes use the north bypass.':'The bridge is open.'} Select recipient buttons below for equivalent information.</desc><defs><pattern id="frGrid" width="30" height="30" patternUnits="userSpaceOnUse"><path d="M30 0H0V30" fill="none" stroke="#43645b" stroke-opacity=".12"/></pattern></defs><rect width="790" height="480" fill="url(#frGrid)"/><path d="M365 0C310 85 397 135 365 215S365 340 420 480" fill="none" stroke="#1c4751" stroke-width="42" opacity=".55"/><path d="M365 0C310 85 397 135 365 215S365 340 420 480" fill="none" stroke="#32616a" stroke-width="1" stroke-dasharray="4 9"/><text x="359" y="345" transform="rotate(72 359 345)" class="fr-map-micro">RIVER</text><text x="24" y="30" class="fr-map-micro">DEMO DISTRICT / NOT A REAL MAP</text>${roads}${routeLines}<text x="280" y="61" text-anchor="middle" class="fr-map-small">North bypass</text><rect x="319" y="187" width="78" height="16" rx="4" fill="#0a1718"/><text x="358" y="199" text-anchor="middle" fill="${world.closedEdges.length?'#ffaaaa':'#8cae9b'}" font-size="9">${world.closedEdges.length?'BRIDGE CLOSED':'BRIDGE OPEN'}</text>${places}${vans}</svg>`;
  }
  function renderFrame(){
    if(!result)return;const e=execution(),world=result.world,records=recordAt(e,minute).map(r=>r.state==='available'&&minute>=world.lots.find(l=>l.id===r.lot).expires?{...r,state:'unallocated',reason:'Expiry window closed; not counted as rescued'}:r);
    put('clock',clock(minute));q('position').value=String(minute);
    put('map-state',e.trace.filter(t=>t.at<=minute).at(-1).type==='end'?'End of window':'Replay · '+(path==='rescue'?'rescue plan':'simple dispatch'));
    drawMap(records);
    q('recipients').innerHTML=world.destinations.map(d=>{const rs=records.filter(r=>r.location===d.id),delivered=rs.filter(r=>r.state==='delivered').reduce((s,r)=>s+r.kg,0),held=rs.filter(r=>['recall-hold','quarantined'].includes(r.state)).reduce((s,r)=>s+r.kg,0);return `<div class="fr-recipient"><button type="button" data-fr-destination="${d.id}" aria-pressed="${filter===d.id}"><strong>${escape(d.name)}</strong><b>${delivered} / ${d.demandKg} kg</b></button><div class="fr-progress" aria-hidden="true"><i style="width:${delivered/d.demandKg*100}%"></i><i class="fr-held-fill" style="width:${held/d.demandKg*100}%"></i></div><small>${held?held+' kg on hold · ':''}${d.cold?'Chilled + ambient accepted':'Ambient stock only'}</small></div>`;}).join('');
    const liveDelivered=records.filter(r=>r.state==='delivered').reduce((s,r)=>s+r.kg,0),transit=records.filter(r=>r.location.startsWith('VAN-')).reduce((s,r)=>s+r.kg,0);
    q('live-counts').innerHTML=`<span>Delivered at ${clock(minute)}<b>${liveDelivered} kg</b></span><span>Currently in transit<b>${transit} kg</b></span>`;
    const lotRecords=filter?records.filter(r=>r.location===filter):records;
    put('lot-filter',filter?world.nodes.find(n=>n.id===filter).name+' · replay state':'All six lots · replay state');
    q('lots').innerHTML=lotRecords.map(r=>{const lot=world.lots.find(l=>l.id===r.lot),remaining=Math.max(0,lot.expires-minute),fraction=Math.min(100,remaining/lot.expires*100);return `<article class="fr-lot"><div class="fr-lot-head"><span class="fr-lot-icon" aria-hidden="true">${lot.cold?'❄':'◇'}</span><span class="fr-lot-mass">${lot.kg} kg</span></div><h3>${escape(lot.name)}</h3><div class="fr-code">${lot.id} / ${lot.batch}</div><div class="fr-lot-status fr-status-${r.state}"><i class="fr-dot" style="background:${colour(r.state)}"></i>${labels[r.state]}</div><p class="fr-lot-reason">${escape(r.reason)}</p><div class="fr-expiry"><i style="width:${fraction}%"></i></div><div class="fr-small">Expiry ${clock(lot.expires)} · ${remaining?remaining+' min left':'window closed'}${r.deliveredAt!==null?' · arrived '+clock(r.deliveredAt):''}</div><details><summary>Inspect evidence &amp; location</summary><p>Location: ${escape(world.nodes.find(n=>n.id===r.location)?.name||r.location)}${r.trip?' · Trip '+r.trip:''}</p>${lot.cold?`<div class="fr-sensors">${lot.readings.map(v=>`<span>${v===null?'Missing':v+'°C'}</span>`).join('')}</div><p>Three fictional pre-dispatch readings. Demo limit: 5°C. Not food-safety guidance.</p>`:'<p>Ambient fixture; no temperature rule applied.</p>'}</details></article>`;}).join('')||'<p class="fr-empty">No stock at this location at the current replay time. Move the clock forward or show all lots.</p>';
    const recalled=[...world.recalls,...world.incidents].some(r=>r.batch==='DAIRY-42'&&r.at<=minute),dairy=records.filter(r=>r.batch==='DAIRY-42');
    put('recall-badge',recalled?'HOLD ACTIVE':'No active recall');
    q('recall').innerHTML=`<div class="fr-batch"><strong>DAIRY-42</strong><p>${recalled?'Recall matched to both lots. Check their current locations below.':'Two linked yoghurt lots. Choose “Recall after delivery” and replay past 09:30.'}</p></div>${dairy.map(r=>`<div class="fr-recall-child"><strong class="fr-status-${r.state}">${r.lot} · ${r.kg} kg · ${labels[r.state]}</strong><span>${escape(world.nodes.find(n=>n.id===r.location)?.name||r.location)}${r.deliveredAt!==null?' · delivered '+clock(r.deliveredAt):''}</span></div>`).join('')}`;
    put('pass',e.checks.filter(c=>c.passed).length+' / '+e.checks.length+' pass');
    q('checks').innerHTML=e.checks.map(c=>`<div class="fr-check"><b>${c.passed?'✓':'✕'}</b><span>${escape(c.label)}</span></div>`).join('');
    q('ledger').innerHTML=e.ledger.map(l=>`<tr><td>${clock(l.at)}</td><td>${escape(l.action)}</td><td>${l.lot}</td><td>${l.kg} kg</td><td>${escape(world.nodes.find(n=>n.id===l.location)?.name||l.location)}</td></tr>`).join('')||'<tr><td colspan="5">No movement recorded. Stock remains accounted for at the hub.</td></tr>';
    q('gates').innerHTML=e.gate.map(g=>`<div>${clock(g.at)} · ${g.lot} · ${g.stage} · ${g.passed?'PASS':'BLOCKED'} · ${escape(g.reason)}</div>`).join('');
  }
  function advance(){if(!result)return;minute=Math.min(270,minute+3);renderFrame();if(minute===270)stop();}
  function play(){
    if(!result||!visible)return;if(timer!==null){stop();return;}
    if(reduced.matches){message('Reduced motion is enabled. Use the replay slider or Next event.');return;}
    if(minute>=270)minute=0;
    timer=setInterval(advance,100);root.dataset.playing='true';put('play','Ⅱ Pause');q('play').setAttribute('aria-pressed','true');
  }
  function setFilter(id){if(!result)return;stop();filter=id;renderFrame();}
  function renderTour(){put('tour-counter',String(tourIndex+1).padStart(2,'0')+' OF 04');put('tour-title',TOUR[tourIndex][0]);put('tour-text',TOUR[tourIndex][1]);put('tour-next',tourIndex===3?'Explore the demo →':'Next →');}
  function closeTour(){q('tour').close();q('tour-open').focus();}
  async function exportEvidence(){
    if(!result)return;const captured=result,version=revision;q('export').disabled=true;
    try {
      const evidence=await makeEvidence(captured);if(disposed||revision!==version||result!==captured)return;
      const url=URL.createObjectURL(new Blob([JSON.stringify(evidence,null,2)+'\n'],{type:'application/json'})),a=document.createElement('a');
      a.href=url;a.download='food-rescue-'+scenario+'.evidence.json';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
      message('Evidence exported. Recheck with apps/ecai/tools/verify_food_rescue.py. The checksum is not a signature.');
    }catch(error){if(!disposed&&revision===version)message(error.message);}
    finally{if(!disposed&&revision===version&&result)q('export').disabled=false;}
  }
  async function present(){
    if(document.fullscreenElement===root){await document.exitFullscreen();return;}
    if(root.dataset.present==='true'){delete root.dataset.present;q('present').setAttribute('aria-pressed','false');return;}
    try{if(!root.requestFullscreen)throw Error('unsupported');await root.requestFullscreen();}catch{root.dataset.present='true';}
    q('present').setAttribute('aria-pressed','true');
  }
  q('scenarios').innerHTML=SCENARIOS.map((s,i)=>`<button type="button" class="fr-scenario" data-fr-scenario="${s.id}" aria-pressed="${s.id===scenario}"><small>${String(i+1).padStart(2,'0')} / ${s.tag}</small><strong>${s.name}</strong><span>${s.description}</span></button>`).join('');
  on(q('scenarios'),'click',e=>{const b=e.target.closest('[data-fr-scenario]');if(b)selectScenario(b.dataset.frScenario);});
  on(q('run'),'click',run);on(q('reset'),'click',()=>{path='rescue';q('path').value=path;selectScenario('everyday');});
  on(q('capacity'),'input',invalidate);on(q('delay'),'change',invalidate);
  on(q('path'),'change',()=>{path=q('path').value;filter=null;renderFrame();});
  on(q('play'),'click',play);on(q('position'),'input',()=>{stop();minute=Number(q('position').value);renderFrame();});
  on(q('next'),'click',()=>{if(!result)return;stop();minute=execution().trace.find(t=>t.at>minute)?.at||270;renderFrame();});
  on(q('map'),'click',e=>{const el=e.target.closest('[data-fr-node]');if(el)setFilter(el.dataset.frNode);});
  on(q('map'),'keydown',e=>{if(['Enter',' '].includes(e.key)){const el=e.target.closest('[data-fr-node]');if(el){e.preventDefault();setFilter(el.dataset.frNode);}}});
  on(q('recipients'),'click',e=>{const el=e.target.closest('[data-fr-destination]');if(el)setFilter(el.dataset.frDestination);});
  on(q('show-all'),'click',()=>setFilter(null));
  on(q('lots'),'click',e=>{if(e.target.closest('summary'))stop();});
  on(q('challenge'),'click',()=>{const world=fixture('recall',controls()),check=validatePlan(world,[{lot:'YOG-04',trip:'A1'}]);put('challenge-result',(check.valid?'Unexpected acceptance':'Blocked: '+check.errors.join('; '))+'. Isolated challenge; no delivery recorded.');});
  on(q('suite'),'click',()=>{const rows=runReferenceSuite(),pass=rows.filter(r=>r.passed).length;put('challenge-result',`${pass} / ${rows.length} scenarios passed · ${pass*14} / ${rows.length*14} local checks across both planners. No remote DamageBDD run.`);});
  on(q('stale-check'),'click',()=>{if(!previous)return;const world=fixture(scenario,controls()),check=validatePlan(world,previous.rescue.plan.assignments),same=canonical(world)===canonical(previous.world);message(same?'The inputs match the previous snapshot. Recompute to restore the current result.':'Stale snapshot rejected for reuse. '+(check.valid?'The old assignments happen to satisfy the changed constraints, but require a fresh input-bound run.':check.errors.join('; ')));});
  on(q('export'),'click',exportEvidence);on(q('present'),'click',present);
  on(q('tour-open'),'click',()=>{stop();tourIndex=0;renderTour();q('tour').showModal();});on(q('tour-close'),'click',closeTour);
  on(q('tour-next'),'click',()=>{if(tourIndex===3)closeTour();else{tourIndex++;renderTour();}});
  on(document,'visibilitychange',()=>{if(document.hidden)stop();});
  on(document,'fullscreenchange',()=>{q('present').setAttribute('aria-pressed',String(document.fullscreenElement===root||root.dataset.present==='true'));});
  on(document,'keydown',e=>{if(e.key==='Escape'&&root.dataset.present==='true'){delete root.dataset.present;q('present').setAttribute('aria-pressed','false');}});
  on(reduced,'change',()=>{if(reduced.matches)stop();});
  run();
  return {setVisible(value){visible=!!value;if(!visible){stop();if(q('tour').open)q('tour').close();if(root.dataset.present==='true'){delete root.dataset.present;q('present').setAttribute('aria-pressed','false');}}},
    refresh(){if(result)renderFrame();else message('Inputs changed. Press Compare rescue plans to recompute.');},
    dispose(){disposed=true;revision++;stop();if(q('tour').open)q('tour').close();delete root.dataset.present;listeners.forEach(off=>off());}};
}
