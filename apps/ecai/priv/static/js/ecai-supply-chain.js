/* Native Recovery Lab. Public demos use isolated temporary server workspaces.
 * Account data and demo capabilities never enter localStorage or innerHTML. */
const PUBLIC_ROOT = "/ecai/supply-chain/public";
export function isPublicSupplyChainRequest(path, method = "GET") {
  return (method === "GET" && [PUBLIC_ROOT, `${PUBLIC_ROOT}/evidence`].includes(path)) ||
    (method === "POST" && ["reset","event","plan","approve","benchmark"].some(action => path === `${PUBLIC_ROOT}/${action}`));
}
const NS = 'http://www.w3.org/2000/svg';
const labels = {cold:'Cold planning',warm:'Warm-start repair',lookup:'Case lookup',ecai:'ECAI index',
  newly_solved:'Newly solved',warm_start:'Warm-start repaired',retrieved_revalidated:'Retrieved + revalidated',retrieved_repaired:'Retrieved + repaired'};
const label = value => labels[value] || String(value ?? '—').replaceAll('_',' ');
const routeColor = id => `var(--sc-route-${Math.max(1, Math.min(6, Number(String(id).slice(1)) || 1))})`;
const ms = value => `${(Number(value || 0) / 1000).toFixed(2)} ms`;

export function assignments(plan) {
  const result = new Map();
  for (const route of plan?.routes || []) for (const stop of route.stops || [])
    result.set(stop.order, {...stop,vehicle:route.vehicle,warehouse:route.warehouse});
  return result;
}
export function vehiclePosition(scenario, route, minute) {
  const nodes = new Map(scenario.nodes.map(n => [n.id,n]));
  let position = nodes.get(scenario.vehicles.find(v => v.id === route.vehicle)?.home);
  for (const leg of route.legs) {
    if (minute < leg.depart) return position;
    if (minute >= leg.arrive) {position = nodes.get(leg.to); continue;}
    let elapsed = minute-leg.depart;
    for (let i=1; i<leg.path.length; i++) {
      const a=nodes.get(leg.path[i-1]),b=nodes.get(leg.path[i]);
      const edge=scenario.edges.find(e => (e.from===a.id&&e.to===b.id)||(e.from===b.id&&e.to===a.id));
      if (!edge) return a;
      if (elapsed<=edge.minutes) {const f=Math.max(0,Math.min(1,elapsed/edge.minutes));return {x:a.x+(b.x-a.x)*f,y:a.y+(b.y-a.y)*f};}
      elapsed-=edge.minutes;
    }
    return nodes.get(leg.to);
  }
  return position;
}

export function initSupplyChain({request,currentToken,managedSession,openLogin}) {
  const root=document.querySelector('[data-panel="supply-chain"]');
  if(!root)return {refresh:async()=>{},reset(){},accessChanged(){},setVisible(){},dispose(){}};
  const $=id=>document.getElementById(id);
  const state={data:null,epoch:0,visible:false,busy:false,disposed:false,controllers:new Set(),
    minute:0,timer:null,selected:null,tab:'network',listeners:[],identity:null};
  const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=String(text);if(cls)n.className=cls;return n;};
  const svg=(tag,attrs={},text)=>{const n=document.createElementNS(NS,tag);for(const [k,v] of Object.entries(attrs))n.setAttribute(k,String(v));if(text!==undefined)n.textContent=String(text);return n;};
  const listen=(target,type,fn)=>{target.addEventListener(type,fn);state.listeners.push(()=>target.removeEventListener(type,fn));};
  const status=(text='',error=false)=>{$('scStatus').textContent=text;$('scStatus').dataset.error=String(error);};
  const active=()=>{const d=state.data;return d?.proposal && d.proposal.input_revision===d.revision?d.proposal:d?.approved;};
  const fresh=()=>!!state.data?.proposal && state.data.proposal.input_revision===state.data.revision;
  const feasible=()=>!!(fresh()?active()?.validation?.valid:state.data?.impact?.valid);

  async function api(path,body) {
    const epoch=state.epoch,token=currentToken(),managed=!!managedSession(),controller=new AbortController();state.controllers.add(controller);
    const base=managed?'/ecai/supply-chain':PUBLIC_ROOT;
    try {
      const response=await request(`${base}${path}`,{signal:controller.signal,ignoreAuth:true,
        ...(!managed?{headers:{'X-ECAI-Lab-Request':'1'}}:{}),
        ...(body===undefined?{}:{method:'POST',body})});
      if(state.disposed||epoch!==state.epoch||token!==currentToken())throw new DOMException('Session changed','AbortError');
      if(response.ok!==true)throw Error(response.error||'Invalid Recovery Lab response');
      return response.data;
    } finally {state.controllers.delete(controller);}
  }
  async function act(fn) {
    try {await fn();} catch(e) {
      if(e.name==='AbortError'||state.disposed)return;
      const why=e.body?.error||e.message||'Recovery Lab request failed.';
      status(why,true);
      if(e.status===410||why==='guest_session_expired') {
        reset();await refresh().catch(()=>{});status('Your temporary demo expired. Load a new scenario to continue.',true);
      } else if(e.status===429) {
        status('The demo is busy or its request limit was reached. Please retry in a few seconds.',true);
      } else if(e.status===409||why==='revision_conflict'||why==='stale_plan') {
        await refresh().catch(()=>{});status('The scenario or proposal changed. Review the refreshed state before retrying.',true);
      }
    }
  }
  async function refresh() {
    accessChanged();if(state.busy||state.disposed)return;
    const epoch=state.epoch;state.busy=true;controls();
    try {state.data=await api('');render();}
    finally {if(epoch===state.epoch){state.busy=false;controls();}}
  }
  async function mutate(path,body={}) {
    if(state.busy)return;
    const epoch=state.epoch;stop();state.busy=true;controls();
    status(path==='/benchmark'?'Measuring all four modes against the same snapshot…':'Checking the scenario and constraints…');
    try {
      if(!state.data)state.data=await api('');
      state.data=await api(path,{expected_revision:state.data?.revision||0,...body});state.minute=0;render();
      status(path==='/approve'?'Simulated plan approved and revalidated. No live dispatch occurred.':
        path==='/event'?'Scenario changed. Generate a fresh recovery before approving.':
        path==='/plan'?`${label(state.data.proposal.source)}. Independent feasibility checks passed.`:
        path==='/benchmark'?'Comparison complete. These are measured single-trial results.':'Scenario ready. Close a road, disable a vehicle, or add an urgent order.');
    } finally {if(epoch===state.epoch){state.busy=false;controls();}}
  }
  function controls() {
    const can=!state.disposed,busy=state.busy,loaded=!!state.data?.exists;
    for(const id of ['scReset','scSeed','scKeepCases'])$(id).disabled=!can||busy;
    for(const id of ['scBridge','scDisable','scUrgent','scPolicy','scStability','scBenchmark','scExport','scVehicle'])$(id).disabled=!can||busy||!loaded;
    root.querySelectorAll('[data-sc-plan]').forEach(b=>b.disabled=!can||busy||!loaded);
    $('scApprove').disabled=!can||busy||!fresh()||!active()?.validation?.valid;
    $('scPlay').disabled=!loaded||busy||!feasible();
    $('scClock').disabled=!loaded||!feasible();
    root.setAttribute('aria-busy',String(busy));
  }
  function accessChanged() {
    const yes=!!managedSession(),identity=yes?`account:${currentToken()}`:'public';
    if(state.identity!==identity){reset();state.identity=identity;}
    $('scAccess').hidden=yes;$('scWorkspace').hidden=false;controls();
  }
  function table(host,headers,rows) {
    host.replaceChildren();
    if(!rows.length){host.append(el('p','No records for this view.','sc-footnote'));return;}
    const t=el('table'),h=el('thead'),hr=el('tr'),b=el('tbody');
    for(const text of headers){const th=el('th',text);th.scope='col';hr.append(th);}h.append(hr);
    for(const row of rows){const tr=el('tr');for(const value of row){const td=el('td');if(value instanceof Node)td.append(value);else td.textContent=String(value??'—');tr.append(td);}b.append(tr);}t.append(h,b);host.append(t);
  }
  function button(text,fn) {const b=el('button',text,'button button-outline');b.type='button';b.addEventListener('click',()=>void act(fn));return b;}
  function render() {
    const d=state.data; if(!d)return;
    $('scLoaded').hidden=!d.exists;$('scRevision').textContent=d.exists?`INPUT REVISION ${d.revision}`:'Not loaded';
    $('scMemoryCount').textContent=String(d.case_count);
    if(!d.exists){controls();return;}
    $('scSeed').value=String(d.scenario.seed);$('scStability').value=String(d.scenario.stability_weight);
    $('scClock').value=String(state.minute);$('scClockLabel').textContent=`t + ${state.minute} min`;
    const oldVehicle=$('scVehicle').value,oldRoute=$('scRoute').value;
    $('scVehicle').replaceChildren();$('scRoute').replaceChildren();
    const all=el('option','All vehicles');all.value='all';$('scRoute').append(all);
    for(const v of d.scenario.vehicles){const a=el('option',`${v.id}${v.available?'':' · unavailable'}`);a.value=v.id;$('scVehicle').append(a);const b=el('option',v.id);b.value=v.id;$('scRoute').append(b);}
    if(d.scenario.vehicles.some(v=>v.id===oldVehicle))$('scVehicle').value=oldVehicle;
    $('scRoute').value=oldRoute||'all';
    const closed=d.scenario.edges.find(e=>e.id==='bridge-central')?.closed;
    $('scBridge').textContent=closed?'Reopen central bridge':'Close central bridge';
    renderMetrics();renderMap();renderTimeline();renderDecision();renderInventory();renderOrders();renderMemory();renderBenchmark();renderEvidence();controls();
  }
  function renderMetrics() {
    const p=active(),m=p?.metrics||{},valid=feasible(),host=$('scMetrics');host.replaceChildren();
    for(const [name,value,warn] of [['On-time orders',valid?`${m.on_time} / ${state.data.scenario.orders.length}`:'—',false],
      ['Unserved orders',valid?m.unserved:'—',valid&&m.unserved>0],['Travel minutes',valid?m.travel_minutes:'—',false],
      ['Changed assignments',valid?m.changed_assignments:'—',false],['Unserved crates',valid?m.at_risk_crates:'—',valid&&m.at_risk_crates>0],
      ['Plan validation',valid?'Passed':'Replan',!valid]]) {
      const box=el('div',undefined,'sc-metric');box.dataset.warning=String(warn);box.append(el('strong',value),el('small',name));host.append(box);
    }
    const impact=state.data.impact,issues=impact?.violations?.length||0;
    $('scImpact').textContent=impact?.valid?'Approved plan remains feasible.':
      `${impact?.affected_orders?.length||0} route-affected orders · ${issues} failed checks on approved plan`;
  }
  function drawRoutes(host,plan,ghost,nodes) {
    const filter=$('scRoute').value;
    for(const r of plan?.routes||[]) {
      if(filter!=='all'&&filter!==r.vehicle)continue;
      for(const leg of r.legs){const points=leg.path.map(id=>nodes.get(id)).filter(Boolean);if(points.length<2)continue;
        const path=svg('polyline',{points:points.map(n=>`${n.x},${n.y}`).join(' '),class:ghost?'sc-route-ghost':'sc-route-path',
          ...(!ghost?{stroke:routeColor(r.vehicle)}:{})});host.append(path);
      }
    }
  }
  function renderMap() {
    const s=state.data?.scenario;if(!s)return;
    const host=$('scMap');host.replaceChildren();
    const nodes=new Map(s.nodes.map(n=>[n.id,n])),a=assignments(active()),missing=new Set(s.orders.filter(o=>!a.has(o.id)).map(o=>o.node));
    host.append(svg('path',{d:'M440 0 C425 90 452 140 442 220 S455 340 438 445 L474 445 C489 350 465 290 480 220 S460 90 478 0 Z',class:'sc-river'}));
    host.append(svg('text',{x:38,y:30,class:'sc-map-label'},'WEST DISTRICT'),svg('text',{x:665,y:30,class:'sc-map-label'},'EAST DISTRICT'));
    for(const e of s.edges) {
      const from=nodes.get(e.from),to=nodes.get(e.to),attrs={x1:from.x,y1:from.y,x2:to.x,y2:to.y};
      host.append(svg('line',{...attrs,class:`sc-road${e.closed?' closed':''}`}));
      if(e.closed)host.append(svg('text',{x:(from.x+to.x)/2,y:(from.y+to.y)/2-7,'text-anchor':'middle',class:'sc-closed-marker'},'×'));
      const hit=svg('line',{...attrs,class:'sc-road-hit',tabindex:0,role:'button','aria-label':`${e.closed?'Reopen':'Close'} road ${e.id}`,'data-road':e.id});
      const toggle=()=>{if(!state.busy)void act(()=>mutate('/event',{event:{kind:'road',id:e.id,closed:!e.closed}}));};
      hit.addEventListener('click',toggle);hit.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();toggle();}});hit.addEventListener('focus',stop);host.append(hit);
    }
    if($('scGhost').checked)drawRoutes(host,state.data.approved,true,nodes);
    drawRoutes(host,active(),false,nodes);
    for(const n of s.nodes) {
      if(n.kind==='warehouse') {
        const g=svg('g',{class:'sc-warehouse'});g.append(svg('rect',{x:n.x-25,y:n.y-19,width:50,height:38,rx:9}),svg('text',{x:n.x,y:n.y+4,'text-anchor':'middle'},n.id),svg('text',{x:n.x,y:n.y+34,'text-anchor':'middle'},n.id==='W1'?'West depot':'East depot'));host.append(g);continue;
      }
      const os=s.orders.filter(o=>o.node===n.id),done=feasible()&&os.every(o=>a.has(o.id)&&a.get(o.id).finish<=state.minute);
      const cls=`sc-node${missing.has(n.id)?' unserved':''}${state.selected===n.id?' selected':''}${done?' delivered':''}`;
      const g=svg('g',{class:cls,tabindex:0,role:'button','aria-label':`Inspect shop ${n.id}`});
      g.append(svg('circle',{cx:n.x,cy:n.y,r:16}),svg('text',{x:n.x,y:n.y+4,'text-anchor':'middle'},n.id));
      const select=()=>{state.selected=n.id;renderSelection();renderMap();};
      g.addEventListener('click',select);g.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();select();}});g.addEventListener('focus',stop);host.append(g);
    }
    for(const r of active()?.routes||[]) {
      if($('scRoute').value!=='all'&&$('scRoute').value!==r.vehicle)continue;
      const pos=vehiclePosition(s,r,state.minute);if(!pos)continue;
      const g=svg('g',{class:'sc-truck','pointer-events':'none','data-vehicle':r.vehicle});
      g.append(svg('rect',{x:pos.x-13,y:pos.y-28,width:27,height:19,rx:5,fill:routeColor(r.vehicle)}),svg('text',{x:pos.x,y:pos.y-15,'text-anchor':'middle'},r.vehicle));host.append(g);
    }
  }
  function renderTimeline() {
    const p=active();if(!p)return;const host=$('scTimeline');host.replaceChildren();
    const width=900,left=55,scale=(width-left-20)/240,height=45+p.routes.length*34;
    const chart=svg('svg',{viewBox:`0 0 ${width} ${height}`,role:'img','aria-label':'Vehicle travel and delivery schedule in simulated minutes'});
    for(let m=0;m<=240;m+=30){const x=left+m*scale;chart.append(svg('line',{x1:x,y1:20,x2:x,y2:height-5,class:'sc-time-grid'}),svg('text',{x,y:12,class:'sc-time-label','text-anchor':'middle'},`${m}m`));}
    p.routes.forEach((r,i)=>{const y=32+i*34;chart.append(svg('text',{x:5,y:y+13,class:'sc-time-label'},r.vehicle),svg('rect',{x:left,y,width:Math.min(r.return_at,240)*scale,height:17,rx:4,class:'sc-time-base'}));
      for(const l of r.legs){chart.append(svg('rect',{x:left+l.depart*scale,y,width:Math.max(1,(l.arrive-l.depart)*scale),height:17,fill:routeColor(r.vehicle),opacity:.45}));}
      for(const stop of r.stops){const order=state.data.scenario.orders.find(o=>o.id===stop.order);if(!order)continue;
        const rect=svg('rect',{x:left+stop.service_start*scale,y,width:Math.max(2,(stop.finish-stop.service_start)*scale),height:17,fill:routeColor(r.vehicle)});
        rect.append(svg('title',{},`${stop.order}: delivery ${stop.finish} min / deadline ${order.latest} min`));chart.append(rect,svg('line',{x1:left+order.latest*scale,y1:y-3,x2:left+order.latest*scale,y2:y+20,class:'sc-time-deadline'}));}
    });
    chart.append(svg('line',{x1:left+state.minute*scale,y1:17,x2:left+state.minute*scale,y2:height-4,class:'sc-time-cursor'}));host.append(chart);
  }
  function renderDecision() {
    const p=state.data.proposal||state.data.approved,stale=!!state.data.proposal&&!fresh();
    $('scSource').textContent=stale?'Stale proposal':label(p?.source||'Baseline');
    $('scValidation').textContent=stale?'Inputs changed after this proposal. Generate a fresh recovery.':
      feasible()?'Feasible under the model. Capacity, roads, deadlines, stock and shelf life checked.':'Approved plan no longer fits the scenario. Recovery is required.';
    const facts=$('scDecisionFacts');facts.replaceChildren();
    for(const [name,value] of [['Input revision',p?.input_revision],['Current revision',state.data.revision],['Recovery time',ms(p?.total_us)],
      ['Memory match',label(p?.retrieval?.kind||'none')],['Retrieved case',p?.retrieval?.case_id?.slice(0,12)||'—'],['Search starts',p?.search_starts],['Selected start',typeof p?.selected_start==='number'?`Fresh ${p.selected_start+1}`:label(p?.selected_start)],['Global optimum','Not proven']])facts.append(el('dt',name),el('dd',value));
    const rejected=$('scRejected');rejected.replaceChildren();
    for(const r of p?.rejected||[])rejected.append(el('p',`${r.order}: ${label(r.reason)}`));
    if(!p?.rejected?.length)rejected.append(el('p','No rejected fragments recorded.'));
    renderSelection();
  }
  function renderSelection() {
    const host=$('scSelection');host.replaceChildren();
    if(!state.selected){host.textContent='Select a shop on the map.';return;}
    const a=assignments(active()),os=state.data.scenario.orders.filter(o=>o.node===state.selected||o.id===state.selected);
    for(const o of os){const x=a.get(o.id);host.append(el('strong',`${o.id} · ${o.node}`),el('p',`${o.quantity} ${o.product} crates · priority ${o.priority} · deadline ${o.latest} min`),
      el('p',x?`${x.warehouse} → ${x.vehicle} → delivery ${x.finish} min`:'Unserved in the displayed plan.'));
      host.append(button('Increase this order by 1 crate',()=>mutate('/event',{event:{kind:'demand',id:o.id,quantity:Math.min(22,o.quantity+1)}})));
    }
  }
  function renderInventory() {
    const host=$('scInventory');host.replaceChildren();const allocations=active()?.metrics?.stock_allocations||[];
    for(const w of state.data.scenario.warehouses)for(const [product,total] of Object.entries(w.stock)){
      const used=allocations.find(a=>a.warehouse===w.id&&a.product===product)?.quantity||0;
      const row=el('div',undefined,'sc-stock'),bar=el('progress');bar.max=total;bar.value=used;bar.setAttribute('aria-label',`${w.id} ${product}: ${used} of ${total} reserved`);
      row.append(el('span',`${w.id} · ${product}`),bar,el('strong',`${used} / ${total}`));host.append(row);
    }
  }
  function renderOrders() {
    const a=assignments(active()),before=assignments(state.data.approved),filter=$('scOrderFilter').value;
    const changed=o=>{const x=a.get(o.id),b=before.get(o.id);return !!b&&(!x||x.vehicle!==b.vehicle||x.warehouse!==b.warehouse);};
    const os=state.data.scenario.orders.filter(o=>filter==='all'||(filter==='unserved'?!a.has(o.id):changed(o)));
    table($('scOrders'),['Order / shop','Product / crates','Priority','Deadline','Source / vehicle','Forecast delivery','Status'],os.map(o=>{
      const x=a.get(o.id),inspect=button(`${o.id} / ${o.node}`,()=>{state.selected=o.id;renderSelection();});
      return [inspect,`${o.product} / ${o.quantity}`,o.priority,`${o.latest} min`,x?`${x.warehouse} / ${x.vehicle}`:'—',x?`${x.finish} min`:'—',
        !x?'Unserved':!feasible()?'Needs revalidation':state.minute>=x.finish?'Delivered in preview':changed(o)?'Reassigned':'Planned'];
    }));
  }
  function renderMemory() {
    $('scMemoryMeta').textContent=`${state.data.case_count} / 64 retained cases · ${state.data.terms_version} · SHA-256 state identity`;
    table($('scCases'),['Case','On time','Unserved','Travel','Curve address','Inspect'],state.data.cases.map(c=>[
      c.id.slice(0,12),c.metrics.on_time,c.metrics.unserved,`${c.metrics.travel_minutes} min`,label(c.curve_address?.status),
      button('Inspect',()=>{$('scCaseDetail').textContent=JSON.stringify(c,null,2);})]));
  }
  function renderBenchmark() {
    const b=state.data.benchmark;
    if(!b){$('scBenchmarkTable').replaceChildren();$('scBenchmarkNote').textContent='No benchmark has run for this revision. Results are measured, never prefilled.';return;}
    table($('scBenchmarkTable'),['Mode','End-to-end','On time','Unserved','Travel','Changes','Decision path','Validated'],b.rows.map(r=>[
      label(r.mode),ms(r.total_us),r.metrics.on_time,r.metrics.unserved,r.metrics.travel_minutes,r.metrics.changed_assignments,label(r.source),r.valid?'Passed':'Failed']));
    $('scBenchmarkNote').textContent=`Revision ${b.input_revision} · ${b.case_count} retained cases. ${b.comparison}`;
  }
  function renderEvidence() {
    const check=active()?.validation,host=$('scChecks');host.replaceChildren();host.className='sc-checks';
    for(const c of check?.checks||[])host.append(el('span',`${feasible()?'✓':'Review'} ${label(c)}`));
    table($('scHistory'),['Time','Revision','Event','Details'],state.data.history.map(e=>[
      new Date(e.at_ms).toLocaleTimeString(),e.revision,label(e.kind),JSON.stringify(e.details)]));
  }
  function tab(name) {
    state.tab=name;root.querySelectorAll('[data-sc-pane]').forEach(p=>p.hidden=p.dataset.scPane!==name);
    root.querySelectorAll('[data-sc-tab]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.scTab===name)));
    if(name!=='network')stop();
  }
  function stop() {if(state.timer)clearInterval(state.timer);state.timer=null;$('scPlay').textContent='Play preview';}
  function tick() {$('scClock').value=String(state.minute);$('scClockLabel').textContent=`t + ${state.minute} min`;renderMap();renderTimeline();}
  function play() {
    if(state.timer){stop();renderOrders();return;}if(!feasible())return;
    if(state.minute>=240)state.minute=0;$('scPlay').textContent='Pause preview';
    state.timer=setInterval(()=>{if(!state.visible||document.hidden){stop();return;}state.minute=Math.min(240,state.minute+1);tick();if(state.minute%10===0)renderOrders();if(state.minute>=240){stop();renderOrders();}},100);
  }
  function reset() {
    state.epoch++;stop();for(const c of state.controllers)c.abort();state.controllers.clear();
    state.data=null;state.busy=false;state.selected=null;state.minute=0;
    for(const id of ['scMap','scTimeline','scMetrics','scDecisionFacts','scRejected','scSelection','scInventory','scOrders','scCases','scChecks','scHistory','scBenchmarkTable'])$(id).replaceChildren();
    $('scCaseDetail').textContent='Select a case to inspect its integrity and outcome.';
    $('scSource').textContent='Baseline';$('scValidation').textContent='';$('scLoaded').hidden=true;
    $('scRevision').textContent='Not loaded';$('scMemoryCount').textContent='0';$('scMemoryMeta').textContent='';
    status('Load a scenario to begin.');controls();
  }
  listen($('scSignIn'),'click',()=>openLogin());
  listen($('scReset'),'click',()=>void act(async()=>{
    const seed=Number($('scSeed').value);if(!Number.isSafeInteger(seed)||seed<1||seed>999999)throw Error('Seed must be an integer from 1 to 999999.');
    if(state.data?.exists&&!window.confirm('Replace the current simulated scenario? Recovery memory follows the checkbox above.'))return;
    await mutate('/reset',{seed,keep_cases:$('scKeepCases').checked});
  }));
  listen($('scBridge'),'click',()=>void act(()=>mutate('/event',{event:{kind:'road',id:'bridge-central',closed:!state.data.scenario.edges.find(e=>e.id==='bridge-central').closed}})));
  listen($('scDisable'),'click',()=>void act(()=>{const id=$('scVehicle').value;return mutate('/event',{event:{kind:'vehicle',id,available:!state.data.scenario.vehicles.find(v=>v.id===id).available}});}));
  listen($('scUrgent'),'click',()=>void act(()=>mutate('/event',{event:{kind:'urgent_order'}})));
  listen($('scPolicy'),'click',()=>void act(()=>{const n=Number($('scStability').value);if(!Number.isSafeInteger(n)||n<0||n>100)throw Error('Penalty must be an integer from 0 to 100.');return mutate('/event',{event:{kind:'policy',stability_weight:n}});}));
  for(const b of root.querySelectorAll('[data-sc-plan]'))listen(b,'click',()=>void act(()=>mutate('/plan',{mode:b.dataset.scPlan})));
  listen($('scApprove'),'click',()=>void act(()=>mutate('/approve',{plan_id:state.data.proposal.id})));
  listen($('scBenchmark'),'click',()=>void act(()=>mutate('/benchmark')));
  for(const b of root.querySelectorAll('[data-sc-tab]'))listen(b,'click',()=>tab(b.dataset.scTab));
  listen($('scGhost'),'change',renderMap);listen($('scRoute'),'change',renderMap);listen($('scOrderFilter'),'change',renderOrders);
  listen($('scPlay'),'click',play);listen($('scClock'),'input',()=>{stop();state.minute=Number($('scClock').value);tick();renderOrders();});
  listen(document,'visibilitychange',()=>{if(document.hidden)stop();});
  listen($('scExport'),'click',()=>void act(async()=>{
    const evidence=await api('/evidence'),blob=new Blob([JSON.stringify(evidence,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob);
    const link=el('a');link.href=url;link.download='ecai-supply-chain-evidence.json';document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }));
  accessChanged();
  return {refresh,reset,accessChanged,setVisible(value){state.visible=!!value;if(!value)stop();},
    dispose(){reset();state.disposed=true;for(const off of state.listeners)off();state.listeners=[];controls();}};
}
