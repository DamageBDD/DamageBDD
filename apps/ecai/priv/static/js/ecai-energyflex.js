import {PRESETS, makeFixture, compare, checkPlan, makeEvidence, infeasibleExplanation} from './energyflex-model.js';

const money = cents => cents === null || cents === undefined ? '—' : `A$${(cents/100).toFixed(2)}`;
const esc = text => String(text).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const endTime = slot => `${17+slot}:00`;
const SVG = 'http://www.w3.org/2000/svg';
const TOURS = [
  ['Welcome to your energy lab','You are managing three electric vehicles at one building. Each needs 14 kWh before departure. Start with the evening commute: the reference example is already calculated.'],
  ['Change the conditions','Choose a scenario, move the power-limit slider or change Vehicle A’s departure. After a manual change, press Compare charging plans. Old results are invalidated rather than silently reused.'],
  ['Follow the energy','Press Play to watch six hours unfold. Switch between the optimised plan and the conventional baselines. Green cells show charging; hatched cells are outside a vehicle’s available time.'],
  ['Challenge the result','Lower the limit or test a duplicate hour at the verification desk. Export the evidence and use the included Python checker to recalculate it independently. This is a synthetic local demo, not live equipment control.']
];

export function initEnergyFlex({root = document.getElementById('energyFlex'), visible: initiallyVisible = false} = {}) {
  const empty={setVisible(){},refresh(){},dispose(){}};
  if (!root) return empty;
  if (root.__energyFlex) return root.__energyFlex;
  const q = name => root.querySelector(`[data-ef="${name}"]`);
  const text = (name,value) => {q(name).textContent=value;};
  const listeners=[];
  function on(target,event,handler) {target.addEventListener(event,handler);listeners.push(()=>target.removeEventListener(event,handler));}
  let preset='evening',fixture=makeFixture(),result=null,dirty=false,frame=0,selected='optimal',timer=null,visible=initiallyVisible,disposed=false,tourIndex=0,exporting=false,generation=0;
  const reduced=window.matchMedia('(prefers-reduced-motion: reduce)');
  function say(message,error=false){text('message',message);q('message').classList.toggle('is-error',error);}
  function current(){return result && !dirty ? result.strategies[selected] : null;}
  function stop(){if(timer!==null)clearInterval(timer);timer=null;root.dataset.playing='false';text('play','▶ Play');q('play').setAttribute('aria-label','Play the six-hour charging replay');}
  function controls(){
    const valid=Boolean(current()?.plan);
    q('play').disabled=!valid;q('replay').disabled=!valid;
    q('export').disabled=dirty||!result||exporting;
    q('tamper').disabled=dirty||!result?.strategies.optimal.plan;
    q('plan').disabled=dirty||!result;
    q('run').textContent=dirty?'Recalculate this scenario →':'Compare charging plans →';
  }
  function readControls(){return makeFixture(preset,{capacity_kw:Number(q('capacity').value),deadline:Number(q('departure').value)});}
  function updateControls(){
    q('capacity').value=String(fixture.capacity_kw);q('departure').value=String(fixture.tasks[0].deadline_slot_exclusive);
    text('capacity-value',`${fixture.capacity_kw} kW`);
    q('capacity').setAttribute('aria-valuetext',`${fixture.capacity_kw} kilowatts shared by the building and chargers`);
    root.querySelectorAll('[data-ef-scenario]').forEach(el=>el.setAttribute('aria-pressed',String(el.dataset.efScenario===preset)));
  }
  function clearKpis(){for(const k of ['saving','cost','energy','passed'])text(k,'—');text('saving-note','Inputs changed. Recalculate to compare.');text('passed-note','No current plan has been verified.');}
  function changed(){
    stop();generation++;const old=result?.strategies.optimal.plan;
    try{fixture=readControls();updateControls();}catch(e){say(e.message,true);return;}
    dirty=true;frame=0;clearKpis();q('test-result').hidden=true;
    let message='Inputs changed. Run the comparison again. No previous savings or verification result applies to these inputs.';
    if(old){const v=checkPlan(fixture,old);message=v.passed?'The previous plan still meets the new limits, but its optimality and costs must be recalculated.':`Previous plan rejected under the new inputs. ${v.failures[0].message} Recalculate to find a replacement.`;}
    q('stale').hidden=false;text('stale',message);say('Your inputs are ready. Press Recalculate this scenario.');
    render();
  }
  function choose(id){preset=id;fixture=makeFixture(id);updateControls();run();}
  function run(){
    stop();generation++;
    try {
      fixture=readControls();result=compare(fixture);dirty=false;frame=0;selected='optimal';q('plan').value=selected;
      q('stale').hidden=true;q('test-result').hidden=true;
      const opt=result.strategies.optimal.verification, c=result.comparison;
      text('saving',money(c.saving_cents));text('saving-note',c.comparable?`${((c.saving_basis_points??0)/100).toFixed(1)}% lower total variable cost · same service`:'No valid like-for-like savings comparison.');
      text('cost',opt?money(opt.metrics.total_variable_energy_cost_cents):'No plan');
      text('energy',opt?`${opt.metrics.charging_energy_kwh} / ${opt.metrics.required_energy_kwh} kWh`:'Unmet');
      text('passed',opt?`${opt.checks.filter(x=>x.passed).length} / ${opt.checks.length} pass`:'No feasible plan');
      text('passed-note',opt?'Constraints checked locally for this plan.':'No plan was labelled safe or successful.');
      say(opt?`Comparison ready. ${result.search.candidate_assignments} assignments checked. Press Play or try a different condition.`:infeasibleExplanation(fixture));
      render();
    } catch(e) {dirty=true;clearKpis();say(e.message,true);render();}
  }
  function render(){renderScene();renderChart();renderTimeline();renderComparison();renderChecks();controls();}
  function renderScene(){
    const entry=current(),plan=entry?.plan, active=frame<6&&plan, slot=Math.min(frame,5), load=active?entry.verification.metrics.load_kw_by_slot[slot]:fixture.base_load_kw[slot];
    const completed=frame===6;
    text('clock',endTime(frame));q('replay').value=String(frame);text('replay-label',endTime(frame));
    q('replay').setAttribute('aria-valuetext',`${endTime(frame)}, ${frame} of 6 charging hours completed`);
    text('scene-status',dirty?'Inputs changed · plan pending':!plan?'No feasible schedule selected':completed?'Six-hour replay complete':`${load} / ${fixture.capacity_kw} kW · current hour`);
    q('scene').setAttribute('aria-label',`${endTime(frame)}. ${!plan?'No current plan.':completed?'Replay complete.':`Site load ${load} kilowatts; limit ${fixture.capacity_kw} kilowatts.`}`);
    const live = f => f ? 'ef-flow' : 'ef-wire';
    let cars='',wires='';
    fixture.tasks.forEach((t,i)=>{
      const y=68+i*86, charging=Boolean(active&&plan[t.id].includes(slot)), available=frame>=t.release_slot&&frame<t.deadline_slot_exclusive;
      const supplied=plan?plan[t.id].filter(s=>s<frame).length*t.power_kw:0;
      const fill=charging?'#a8f079':available?'#6c969b':'#3a525f';
      wires+=`<path class="${live(charging)}" d="M463 155 H520 V${y+13} H594"/>`;
      cars+=`<g transform="translate(582 ${y-13})"><rect x="-10" y="-10" width="145" height="66" rx="11" fill="${charging?'#223a2a':'#12222a'}" stroke="${charging?'#527d43':'#29414b'}"/>
        <path d="M19 34 L23 18 L40 9 H76 L92 20 L105 24 V39 H17 Z" fill="${fill}" stroke="#a2bcb7" stroke-width="1"/>
        <path d="M43 13 H73 L84 22 H32 Z" fill="#152a32"/><circle cx="35" cy="38" r="7" fill="#0b161d" stroke="#6c969b"/><circle cx="85" cy="38" r="7" fill="#0b161d" stroke="#6c969b"/>
        <text x="-51" y="18" fill="#bdd0ce" font-size="11">${t.id}</text><text x="119" y="26" fill="${charging?'#a8f079':'#9bb0b6'}" font-size="16">${charging?'ϟ':supplied===t.grid_energy_kwh?'✓':'·'}</text></g>`;
    });
    q('scene').innerHTML=`<svg viewBox="0 0 760 300" xmlns="${SVG}" aria-hidden="true">
      <path d="M80 258 L383 281 L735 259" stroke="#243d46" fill="none"/>
      <text x="47" y="53" fill="#98b2b8" font-size="10" letter-spacing="1.7">GRID SUPPLY</text>
      <path d="M81 224 L102 77 L123 224 M90 160 H114 M95 123 H109 M102 77 L84 112 H120 Z M85 190 H119 M67 111 H137 M59 143 H144" fill="none" stroke="#5b7c87" stroke-width="3" stroke-linejoin="round"/>
      <path class="${live(Boolean(active))}" d="M137 143 H197 V155 H265"/>
      <rect x="160" y="175" width="83" height="49" rx="6" fill="#162b34" stroke="#3a5662"/><text x="201" y="194" text-anchor="middle" fill="#a8f079" font-size="11">${fixture.capacity_kw} kW</text><text x="201" y="212" text-anchor="middle" fill="#9bb0b6" font-size="9">SITE LIMIT</text>
      <text x="306" y="52" fill="#98b2b8" font-size="10" letter-spacing="1.7">THE BUILDING</text>
      <polygon points="286,96 354,66 446,96 379,127" fill="#27414a" stroke="#4b6874"/>
      <polygon points="286,96 379,127 379,235 286,204" fill="#1b343e" stroke="#45616b"/>
      <polygon points="379,127 446,96 446,204 379,235" fill="#142a34" stroke="#45616b"/>
      ${[0,1,2].flatMap(r=>[0,1,2].map(c=>`<path d="M${298+c*24} ${116+r*29+c*8} l14 5 v16 l-14 -5z" fill="${(r+c)%2===0?'#e0b977':'#547776'}" opacity="${(r+c)%2===0?'.8':'.4'}"/>`)).join('')}
      ${[0,1,2].flatMap(r=>[0,1].map(c=>`<path d="M${393+c*23} ${132+r*28-c*10} l13 -6 v15 l-13 6z" fill="#619392" opacity=".5"/>`)).join('')}
      <path class="${live(Boolean(active))}" d="M446 155 H463"/>${wires}${cars}
      <text x="300" y="270" fill="#a8f079" font-size="11">${dirty?'PLAN PENDING':!plan?'NO FEASIBLE PLAN':completed?'REPLAY COMPLETE':`${load} kW SITE LOAD`}</text>
    </svg>`;
    q('vehicles').innerHTML=fixture.tasks.map(t=>{
      const supplied=plan?plan[t.id].filter(s=>s<frame).length*t.power_kw:0,charging=Boolean(active&&plan[t.id].includes(slot));
      const status=!plan?'No current plan':supplied===t.grid_energy_kwh?'Ready to depart':frame>=t.deadline_slot_exclusive?'Deadline reached':charging?'Charging this hour':'Waiting for its slot';
      return `<div class="ef-vehicle${charging?' is-charging':''}"><div class="ef-vehicle-title"><strong>${t.id}</strong><span>Leaves ${endTime(t.deadline_slot_exclusive)}</span></div><meter min="0" max="14" value="${supplied}" aria-label="${t.id}: ${supplied} of 14 kilowatt hours delivered"></meter><p>${supplied} / 14 kWh · ${status}</p></div>`;
    }).join('');
  }
  function renderChart(){
    const entry=current(),plan=entry?.plan,load=entry?.verification?.metrics.load_kw_by_slot||fixture.base_load_kw;
    const early=!dirty?result?.strategies.earliest.verification.metrics.load_kw_by_slot:null;
    const W=520,H=270,left=42,right=502,top=23,bottom=163,n=6,col=(right-left)/n;
    const max=Math.max(30,fixture.capacity_kw+4,...load,...(early||[]));const y=v=>bottom-v/max*(bottom-top);
    let svg=`<svg viewBox="0 0 ${W} ${H}" xmlns="${SVG}" aria-hidden="true"><text x="5" y="13" fill="#afc3c7" font-size="9">kW</text>`;
    for(const tick of [0,10,20,30])svg+=`<line x1="${left}" x2="${right}" y1="${y(tick)}" y2="${y(tick)}" stroke="#29404a"/><text x="${left-8}" y="${y(tick)+3}" text-anchor="end" fill="#afc3c7" font-size="9">${tick}</text>`;
    for(let s=0;s<n;s++){
      const x=left+col*s+col*.22,bw=col*.56,base=fixture.base_load_kw[s];
      if(frame===s)svg+=`<rect x="${left+col*s+3}" y="${top}" width="${col-6}" height="${H-top-3}" rx="5" fill="#8cf0d609" stroke="#4c8376" stroke-dasharray="2 4"/>`;
      svg+=`<g tabindex="0" role="button" aria-label="Inspect ${fixture.slot_labels[s]}" data-ef-slot="${s}"><rect x="${left+col*s}" y="${top}" width="${col}" height="${H-top}" fill="transparent"/>
       <rect x="${x}" y="${y(base)}" width="${bw}" height="${bottom-y(base)}" fill="#405b68"/>
       <rect x="${x}" y="${y(load[s])}" width="${bw}" height="${Math.max(0,y(base)-y(load[s]))}" fill="${plan?'#a8f079':'#405b68'}" rx="2"/>
       ${early?`<rect x="${x-4}" y="${y(early[s])}" width="${bw+8}" height="${bottom-y(early[s])}" rx="3" fill="none" stroke="#a2bec3" stroke-width="1"/>`:''}
       <text x="${x+bw/2}" y="181" text-anchor="middle" fill="#b6cacb" font-size="9">${fixture.slot_labels[s]}</text></g>`;
    }
    svg+=`<line x1="${left}" x2="${right}" y1="${y(fixture.capacity_kw)}" y2="${y(fixture.capacity_kw)}" stroke="#ffc27b" stroke-width="1.5" stroke-dasharray="5 4"/>
      <text x="${right-3}" y="${Math.max(10,y(fixture.capacity_kw)-6)}" text-anchor="end" fill="#ffc27b" font-size="9">${fixture.capacity_kw} kW LIMIT</text>
      <text x="${left}" y="205" fill="#afc3c7" font-size="9">TARIFF · cents/kWh</text>`;
    const pmax=Math.max(...fixture.prices_cents_per_kwh),py=v=>255-v/pmax*35,px=s=>left+col*(s+.5);
    svg+=`<path d="${fixture.prices_cents_per_kwh.map((v,s)=>`${s?'L':'M'}${px(s)},${py(v)}`).join(' ')}" fill="none" stroke="#ffc27b" stroke-width="2"/>`;
    fixture.prices_cents_per_kwh.forEach((v,s)=>{svg+=`<circle cx="${px(s)}" cy="${py(v)}" r="3" fill="#ffc27b"/><text x="${px(s)}" y="${py(v)-9}" text-anchor="middle" fill="#ffce99" font-size="10">${v}¢</text>`;});
    q('chart').innerHTML=svg+'</svg>';
    // A semantic equivalent is provided by the exact-data table.
    q('chart').querySelector('svg').removeAttribute('aria-hidden');
    q('chart').querySelector('svg').setAttribute('aria-label','Select an hour to inspect site load and tariff');
    text('peak',plan?`${Math.max(...load)} kW peak`:dirty?'Awaiting run':'No feasible plan');
    q('hourly').innerHTML=`<table><caption class="ef-sr-only">Hourly inputs and selected plan</caption><thead><tr><th>Hour</th><th>Tariff ¢/kWh</th><th>Building kW</th><th>Selected kW</th></tr></thead><tbody>${fixture.slot_labels.map((t,s)=>`<tr><td>${t}</td><td>${fixture.prices_cents_per_kwh[s]}</td><td>${fixture.base_load_kw[s]}</td><td>${plan?load[s]:'—'}</td></tr>`).join('')}</tbody></table>`;
  }
  function renderTimeline(){
    const plan=current()?.plan;
    q('timeline').innerHTML=`<table class="ef-timeline"><caption class="ef-sr-only">Selected vehicle charging schedule</caption><thead><tr><th>Vehicle</th>${fixture.slot_labels.map(t=>`<th>${t}</th>`).join('')}</tr></thead><tbody>${fixture.tasks.map(t=>`<tr><td><strong>${t.id}</strong><small>Due ${endTime(t.deadline_slot_exclusive)}</small></td>${fixture.slot_labels.map((_,s)=>{
      const closed=s>=t.deadline_slot_exclusive||s<t.release_slot,filled=Boolean(plan?.[t.id].includes(s));
      return `<td><span class="ef-slot${closed?' is-closed':''}${filled?' is-filled':''}${frame===s?' is-now':''}">${filled?'ϟ 7 kWh':closed?'Away':plan?'—':'Pending'}</span></td>`;
    }).join('')}</tr>`).join('')}</tbody></table>`;
  }
  function renderComparison(){
    if(dirty||!result){q('comparison').innerHTML='<p class="ef-empty">Run the comparison to see current results. Previous numbers are not being reused.</p>';text('comparison-note','All strategies use identical inputs and constraints.');text('search-note','');return;}
    const names={earliest:['Charge early','Conventional · earliest departure first'],tariff:['Tariff-aware','Conventional · cheapest available hours'],optimal:['Exact optimum','Fully enumerated · reference optimiser']};
    q('comparison').innerHTML=`<table><caption class="ef-sr-only">Cost and constraint comparison</caption><thead><tr><th>Strategy</th><th>Total cost</th><th>Peak</th><th>Constraints</th></tr></thead><tbody>${Object.entries(result.strategies).map(([key,v])=>{
      const checked=v.verification,valid=checked?.passed;
      return `<tr><td><strong>${names[key][0]}</strong><small>${names[key][1]}</small></td><td>${valid?money(checked.metrics.total_variable_energy_cost_cents):'—'}</td><td>${checked?checked.metrics.peak_kw+' kW':'—'}</td><td><span class="ef-result${valid?'':' is-fail'}">${valid?'PASS':checked?'INCOMPLETE':'NO PLAN'}</span></td></tr>`;
    }).join('')}</tbody></table>`;
    text('comparison-note',result.comparison.tariff_matches_optimum?'A fair result: the conventional tariff-aware baseline matches the optimum here. These savings do not establish an AI or ECAI advantage.':result.strategies.optimal.plan?'Compare only complete, valid plans. An incomplete plan cannot claim savings by delivering less energy.':'No schedule meets all constraints in this discrete model. No savings are claimed.');
    text('search-note',`${result.search.candidate_assignments.toLocaleString()} assignments evaluated · ${result.search.feasible_assignments.toLocaleString()} feasible · exhaustive search completed. Total cost includes the same building demand in every strategy.`);
  }
  function renderChecks(){
    const v=current()?.verification;
    if(!v){q('checks').innerHTML=`<p class="ef-empty">${dirty?'No current result. Recalculate after changing the inputs.':esc(infeasibleExplanation(fixture))}</p>`;return;}
    q('checks').innerHTML=v.checks.map(c=>`<div class="ef-check${c.passed?'':' is-fail'}"><b aria-hidden="true">${c.passed?'✓':'×'}</b><span>${esc(c.label)}<span class="ef-sr-only">: ${c.passed?'passed':'failed'}</span></span></div>`).join('');
    if(!v.passed)q('checks').insertAdjacentHTML('beforeend',`<p class="ef-card-note">${esc(v.failures[0].message)}</p>`);
  }
  function renderReplay(){renderScene();renderChart();renderTimeline();controls();}
  function play(){
    if(timer!==null){stop();return;}if(!current()?.plan||!visible||document.hidden)return;
    if(frame>=6)frame=0;
    text('play','Ⅱ Pause');q('play').setAttribute('aria-label','Pause the charging replay');root.dataset.playing=String(!reduced.matches);
    renderReplay();timer=setInterval(()=>{if(disposed||!visible||document.hidden){stop();return;}frame++;renderReplay();if(frame>=6)stop();},1000);
  }
  function jump(s){if(!current()?.plan)return;stop();frame=s;renderReplay();}
  function tour(){const t=TOURS[tourIndex];text('tour-counter',`GETTING STARTED · ${tourIndex+1} OF ${TOURS.length}`);text('tour-title',t[0]);text('tour-copy',t[1]);q('tour-prev').disabled=tourIndex===0;text('tour-next',tourIndex===TOURS.length-1?'Start exploring ✓':'Next →');}
  async function exportEvidence(){
    if(dirty||!result||exporting)return;
    const thisGeneration=generation;
    exporting=true;controls();
    try {
      const evidence=await makeEvidence(fixture,result);
      if(disposed||generation!==thisGeneration){if(!disposed)say('Inputs changed during export. Recalculate, then export the new result.');return;}
      const blob=new Blob([JSON.stringify(evidence,null,2)+'\n'],{type:'application/json'}),url=URL.createObjectURL(blob);
      const a=document.createElement('a');a.href=url;a.download=`ENERGYFLEX-${preset}.evidence.json`;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
      say('Evidence exported. The included Python checker can verify the checksum, constraints, metrics and exact optimum.');
    }catch(e){say(e.message,true);}finally{exporting=false;if(!disposed)controls();}
  }
  q('presets').innerHTML=PRESETS.map(p=>`<button type="button" class="ef-preset" data-ef-scenario="${p.id}" aria-pressed="${p.id===preset}"><span>${p.icon} / SCENARIO</span><strong>${esc(p.title)}</strong><small>${esc(p.hint)}</small></button>`).join('');
  on(q('presets'),'click',e=>{const button=e.target.closest('[data-ef-scenario]');if(button)choose(button.dataset.efScenario);});
  on(q('capacity'),'input',changed);on(q('departure'),'change',changed);on(q('run'),'click',run);on(q('reset'),'click',()=>choose('evening'));
  on(q('play'),'click',play);on(q('replay'),'input',()=>jump(Number(q('replay').value)));
  on(q('plan'),'change',()=>{stop();selected=q('plan').value;frame=0;render();});
  on(q('chart'),'click',e=>{const target=e.target.closest('[data-ef-slot]');if(target)jump(Number(target.dataset.efSlot));});
  on(q('chart'),'keydown',e=>{if(['Enter',' '].includes(e.key)){const target=e.target.closest('[data-ef-slot]');if(target){e.preventDefault();const s=Number(target.dataset.efSlot);jump(s);q('chart').querySelector(`[data-ef-slot="${s}"]`)?.focus();}}});
  on(q('squeeze'),'click',()=>{q('capacity').value='16';changed();q('run').focus();});
  on(q('tamper'),'click',()=>{
    if(!result?.strategies.optimal.plan||dirty)return;
    const plan=JSON.parse(JSON.stringify(result.strategies.optimal.plan));plan['EV-A']=[plan['EV-A'][0],plan['EV-A'][0]];
    const v=checkPlan(fixture,plan);q('test-result').hidden=false;text('test-result',v.passed?'Unexpected result: invalid plan accepted.':'Rejected: a duplicate hour cannot deliver the required energy. The checker caught the duplicate and the energy shortfall. Your original valid plan is unchanged.');
  });
  on(q('export'),'click',exportEvidence);
  on(q('tour-open'),'click',()=>{stop();tourIndex=0;tour();q('tour').showModal();});
  on(q('tour-prev'),'click',()=>{if(tourIndex>0)tourIndex--;tour();});
  on(q('tour-next'),'click',()=>{if(tourIndex===TOURS.length-1){q('tour').close();return;}tourIndex++;tour();});
  on(q('present'),'click',async()=>{
    try{if(document.fullscreenElement===root)await document.exitFullscreen();else if(root.dataset.present==='true'){root.dataset.present='false';text('present','Presentation mode ⛶');}else if(root.requestFullscreen)await root.requestFullscreen();else{root.dataset.present='true';text('present','Exit presentation ×');}}catch{root.dataset.present=root.dataset.present==='true'?'false':'true';text('present',root.dataset.present==='true'?'Exit presentation ×':'Presentation mode ⛶');}
  });
  on(document,'fullscreenchange',()=>text('present',document.fullscreenElement===root?'Exit presentation ×':'Presentation mode ⛶'));
  on(document,'keydown',e=>{if(e.key==='Escape'&&root.dataset.present==='true'){root.dataset.present='false';text('present','Presentation mode ⛶');}});
  on(document,'visibilitychange',()=>{if(document.hidden)stop();});
  on(reduced,'change',()=>{if(reduced.matches)root.dataset.playing='false';});
  const api={
    setVisible(value){visible=Boolean(value);if(!visible){stop();if(q('tour').open)q('tour').close();root.dataset.present='false';if(document.fullscreenElement===root)void document.exitFullscreen().catch(()=>{});}},
    refresh(){if(!disposed)run();},
    dispose(){if(disposed)return;disposed=true;generation++;stop();for(const remove of listeners)remove();if(q('tour').open)q('tour').close();root.dataset.present='false';if(document.fullscreenElement===root)void document.exitFullscreen().catch(()=>{});delete root.__energyFlex;}
  };
  root.__energyFlex=api;updateControls();run();return api;
}
