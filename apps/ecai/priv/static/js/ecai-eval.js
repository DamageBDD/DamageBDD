/* Account-isolated evaluation workspace. No innerHTML, credentials or localStorage. */
export function initEvaluation({request, currentToken, managedSession, isAdmin, openLogin}) {
  const $ = id => document.getElementById(id);
  const root = document.querySelector('[data-panel="evaluation"]');
  if (!root) return {refresh:async()=>{}, reset(){}, accessChanged(){}, setVisible(){}, dispose(){}};
  const state = {epoch:0, visible:false, loading:false, disposed:false, controllers:new Set(), snapshot:null,
    node:null, selectedRun:null, runData:null, review:null, timer:null, fields:new Map(), nodeFields:new Map()};
  const esc = encodeURIComponent;
  function el(tag, text, cls) {const x=document.createElement(tag); if(text!==undefined)x.textContent=String(text); if(cls)x.className=cls; return x;}
  function status(text='', error=false) {$('evalStatus').textContent=text; $('evalStatus').dataset.error=String(error);}
  function showJSON(id, value) {$(id).textContent=JSON.stringify(value,null,2);}
  function newKey() {const id=crypto.randomUUID?.() || [...crypto.getRandomValues(new Uint8Array(16))].map(x=>x.toString(16).padStart(2,'0')).join('');return `eval-${id}`;}
  function button(label, action) {const b=el('button',label,'button button-outline');b.type='button';b.addEventListener('click',()=>void act(action));return b;}
  async function act(fn) {try {await fn();} catch(e) {if(e.name!=='AbortError'&&!state.disposed)status(e.body?.error || e.message || 'Evaluation request failed.',true);}}
  async function api(path, body) {
    if(!managedSession()||!currentToken())throw new Error('Managed email sign-in is required.');
    const epoch=state.epoch, token=currentToken(), controller=new AbortController();state.controllers.add(controller);
    try {
      const response=await request(`/ecai/eval${path}`, {signal:controller.signal, ignoreAuth:true,
        ...(body===undefined?{}:{method:'POST',body})});
      if(epoch!==state.epoch||token!==currentToken()||state.disposed)throw new DOMException('Session changed','AbortError');
      if(response.ok!==true)throw new Error(response.error||'Invalid evaluation response');
      return response.data;
    } finally {state.controllers.delete(controller);}
  }
  function table(hostId, headings, rows) {
    const host=$(hostId);host.replaceChildren();
    if(!rows.length){host.append(el('p','No records in this account.','context-hint'));return;}
    const t=el('table'),head=el('thead'),tr=el('tr'),body=el('tbody');
    for(const h of headings){const th=el('th',h);th.scope='col';tr.append(th);}head.append(tr);
    for(const values of rows){const row=el('tr');for(const value of values){const td=el('td');if(value instanceof Node)td.append(value);else td.textContent=String(value??'—');row.append(td);}body.append(row);}
    t.append(head,body);host.append(t);
  }
  function chooseTab(name) {
    if(name==='node'&&!isAdmin())name='account';
    root.querySelectorAll('[data-eval-pane]').forEach(p=>p.hidden=p.dataset.evalPane!==name);
    root.querySelectorAll('[data-eval-tab]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.evalTab===name)));
    if(name==='reviews')void act(loadReviews);
    if(name==='node')void act(loadNode);
  }
  function accessChanged() {
    const yes=!!managedSession();$('evalAccess').hidden=yes;$('evalWorkspace').hidden=!yes;$('evalNodeTab').hidden=!yes||!isAdmin();
    if(!isAdmin()){$('evalNodeFields').replaceChildren();state.node=null;}
  }
  function field(name, value, meta={}) {
    const label=el('label',meta.label||name.replaceAll('_',' '));let input;
    if(meta.options){input=el('select');input.multiple=!!meta.multiple;for(const op of meta.options){const o=el('option',op.label);o.value=op.value;o.selected=Array.isArray(value)?value.includes(op.value):value===op.value;input.append(o);}}
    else {input=el('input');input.type=typeof value==='boolean'?'checkbox':typeof value==='number'?'number':'text';
      if(input.type==='checkbox')input.checked=value;else input.value=Array.isArray(value)?value.join(', '):String(value??'');
      if(meta.min!==undefined)input.min=String(meta.min);if(meta.max!==undefined)input.max=String(meta.max);if(input.type==='number')input.step='1';}
    input.name=name; input.id=`eval-field-${meta.node?'node-':''}${name}`;label.htmlFor=input.id;label.append(input);
    if(meta.help)label.append(el('small',meta.help,'eval-field-help'));return {label,input,kind:meta.kind||typeof value};
  }
  function values(fields) {
    const result={};for(const [name,f] of fields){const input=f.input;
      if(input.multiple)result[name]=[...input.selectedOptions].map(o=>o.value);
      else if(input.type==='checkbox')result[name]=input.checked;
      else if(input.type==='number'){const n=Number(input.value);if(!Number.isSafeInteger(n))throw new Error(`Invalid integer: ${name}`);result[name]=n;}
      else if(f.kind==='string_list')result[name]=input.value.split(',').map(x=>x.trim()).filter(Boolean);
      else result[name]=input.value;}
    return result;
  }
  function renderSettings(data) {
    state.snapshot=data;const p=data.preferences,n=data.node_policy;
    $('evalNodeState').textContent=n.enabled?'Node evaluation enabled':'Node evaluation disabled';
    $('evalQuota').textContent=`${data.daily_reserved_calls} / ${data.effective.daily_calls} reserved calls today · this account, this node`;
    $('evalRunSubmit').disabled=!data.effective.enabled||!data.effective.target_ids.length;
    const host=$('evalAccountFields');host.replaceChildren();state.fields.clear();
    const options=data.targets.map(t=>({value:t.id,label:`${t.id} · ${t.model} · ${t.remote?'remote':'loopback'}`}));
    const meta={target_ids:{options,multiple:true,help:'Only operator-allowed targets appear.'},
      knowledge_mode:{options:[{value:'none',label:'Unassisted — no retrieved reference context'},{value:'ecai',label:'ECAI references — deterministic term retrieval'}]},
      repetitions:{min:1,max:n.max_repetitions},max_output_tokens:{min:16,max:n.max_output_tokens},
      daily_calls:{min:1,max:n.daily_calls},pass_bps:{min:n.min_pass_bps,max:10000,help:'Basis points: 9500 = 95%. Critical failures always block.'},
      retrieval_k:{min:1,max:20},remote_consent:{help:'Allow sending evaluation prompts and selected reference text to operator-approved remote targets.'}};
    for(const [key,value] of Object.entries(p)){const f=field(key,value,meta[key]||{});state.fields.set(key,f);host.append(f.label);}
    showJSON('evalEffective',data.effective);
    if(data.target_error)status(`Target configuration: ${data.target_error}`,true);
  }
  function renderSuites(suites) {
    const select=$('evalRunSuite'),previous=select.value;select.replaceChildren();
    for(const s of suites){const option=el('option',`${s.name} · ${s.version} · ${s.approvals.length} approval(s)`);option.value=s.id;select.append(option);}
    if(suites.some(s=>s.id===previous))select.value=previous;
    table('evalSuiteList',['Suite / version','Cases','Approval count','Coverage','Inspect'],suites.map(s=>[
      `${s.name} / ${s.version}`,s.cases,s.approvals.length,JSON.stringify(s.coverage),button('Inspect',async()=>{
        showJSON('evalSuiteDetail',await api(`/suites/${esc(s.id)}`));$('evalApproveId').value=s.id;
      })]));
  }
  function renderRuns(runs) {
    table('evalRunList',['Run','Created','Outcomes / planned','Pass rate','Gate','Inspect'],runs.map(r=>[
      r.id.slice(0,12),new Date(r.created_at_ms).toLocaleString(),`${JSON.stringify(r.counts)} / ${r.planned}`,
      `${(r.pass_bps/100).toFixed(1)}%`,r.release_gate?'Pass':'Blocked',button('Open',()=>openRun(r.id))]));
  }
  async function refresh() {
    accessChanged();if(!managedSession()||state.loading||state.disposed)return;
    state.loading=true;const epoch=state.epoch;
    try {
      const [config,suites,runs]=await Promise.all([api('/settings'),api('/suites'),api('/runs')]);
      if(epoch!==state.epoch)return;
      // Do not overwrite an in-progress settings edit during polling.
      if(!state.snapshot)renderSettings(config);
      else {$('evalNodeState').textContent=config.node_policy.enabled?'Node evaluation enabled':'Node evaluation disabled';$('evalQuota').textContent=`${config.daily_reserved_calls} / ${config.effective.daily_calls} reserved calls today`; $('evalRunSubmit').disabled=!config.effective.enabled||!config.effective.target_ids.length;}
      renderSuites(suites);renderRuns(runs);if(state.selectedRun)await openRun(state.selectedRun);
    } finally {if(epoch===state.epoch)state.loading=false;}
  }
  async function openRun(id) {
    const result=await api(`/runs/${esc(id)}`);state.selectedRun=id;state.runData=result;
    $('evalReportPanel').hidden=false;$('evalReportTitle').textContent=`Run ${id.slice(0,12)}`;
    const r=result.report;$('evalGate').textContent=r.release_gate?'Gate passed':'Gate blocked';
    const metrics=$('evalMetrics');metrics.replaceChildren();
    for(const [label,value] of [['Planned trials',r.planned],['Passed / planned',`${(r.pass_bps/100).toFixed(1)}%`],['Critical failures',r.critical_failures],['p95 latency',r.p95_latency_ms===null?'—':`${r.p95_latency_ms} ms`]]){const box=el('div',undefined,'eval-metric');box.append(el('strong',value),el('span',label));metrics.append(box);}
    table('evalTargets',['Target','Planned','Pass rate','Critical failures','Gate'],Object.entries(r.targets).map(([id,v])=>[id,v.planned,`${(v.pass_bps/100).toFixed(1)}%`,v.critical_failures,v.release_gate?'Pass':'Blocked']));
    showJSON('evalFindings',{recommendations:r.recommendations,slices:r.slices,human_review:r.human_review,cost:r.cost});
    $('evalCandidate').value=id;renderCases();
  }
  function renderCases() {
    const r=state.runData?.report;if(!r)return;const filter=$('evalOutcomeFilter').value;
    const cases=r.cases.filter(c=>filter==='all'||(filter==='not_pass'?c.status!=='pass':c.status===filter));
    table('evalCases',['Case / repetition','Target','Dimension','Outcome','Failed checks','Inspect'],cases.map(c=>[
      `${c.case_id} / ${c.repetition}`,c.target_id,`${c.domain} / ${c.dimension}`,c.status,
      c.failed_checks.map(x=>`${x.id}: ${x.reason}`).join('; '),button('Inspect',async()=>showJSON('evalTrial',await api(`/runs/${esc(state.selectedRun)}/attempts/${esc(c.id)}`)))]));
  }
  async function loadReviews() {
    const q=await api('/review-queue');
    table('evalReviewList',['Kind','Owner','ID','Action'],q.items.map(item=>[item.kind,item.owner,(item.task_id||item.id).slice(0,16),button('Review',async()=>{
      const details=await api('/review-detail',Object.fromEntries(Object.entries(item).filter(([k])=>['kind','owner','id','task_id'].includes(k))));
      state.review=item;showJSON('evalReviewDetail',details);$('evalReviewVerdict').disabled=item.kind==='suite';
    })]));
    if(q.total>100)status(`Showing the first 100 of ${q.total} pending review items. Completed reviews leave the queue.`);
  }
  async function loadNode() {
    if(!isAdmin())return;const n=await api('/admin/settings');state.node=n;
    $('evalNodeFields').replaceChildren();state.nodeFields.clear();
    for(const f of n.fields){const data=field(f.name,f.value,{...f,node:true,kind:f.type});state.nodeFields.set(f.name,data);$('evalNodeFields').append(data.label);}
  }
  async function sample(name) {
    const epoch=state.epoch;const resp=await fetch(`/static/eval/${name}.json`,{mode:'same-origin',cache:'no-store'});
    if(!resp.ok)throw new Error('Example not available');const text=await resp.text();if(epoch!==state.epoch)return;
    $('evalDatasetInput').value=text;status('Synthetic example loaded. Review and adapt it before importing.');
  }
  async function downloadEvidence() {
    if(!state.selectedRun)return;const evidence=await api(`/runs/${esc(state.selectedRun)}/evidence`);
    const url=URL.createObjectURL(new Blob([JSON.stringify(evidence,null,2)],{type:'application/json'}));
    const a=el('a');a.href=url;a.download=`ecai-eval-${state.selectedRun}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  function onForm(id,fn) {$(id).addEventListener('submit',e=>{e.preventDefault();const submit=e.submitter;if(submit)submit.disabled=true;void act(async()=>{try{await fn();}finally{if(submit)submit.disabled=false;}});});}
  root.querySelectorAll('[data-eval-tab]').forEach(b=>b.addEventListener('click',()=>chooseTab(b.dataset.evalTab)));
  $('evalSignIn').addEventListener('click',openLogin);
  $('evalRefresh').addEventListener('click',()=>void act(async()=>{await refresh();renderSettings(await api('/settings'));status('Evaluation workspace refreshed.');}));
  $('evalNewKey').addEventListener('click',()=>{$('evalRunKey').value=newKey();status('New key created. Use it only for a deliberately new run.');});
  $('evalLoadDialogue').addEventListener('click',()=>void act(()=>sample('dialogue')));
  $('evalLoadTrading').addEventListener('click',()=>void act(()=>sample('paper-trading')));
  $('evalDatasetFile').addEventListener('change',()=>void act(async()=>{const file=$('evalDatasetFile').files?.[0];if(!file)return;if(file.size>2097152)throw new Error('Dataset exceeds 2 MiB');const epoch=state.epoch;const text=await file.text();if(epoch===state.epoch)$('evalDatasetInput').value=text;}));
  $('evalOutcomeFilter').addEventListener('change',renderCases);
  $('evalEvidence').addEventListener('click',()=>void act(downloadEvidence));
  $('evalCancel').addEventListener('click',()=>void act(async()=>{if(state.selectedRun&&confirm('Cancel remaining work? A dispatched request may already be billable.')){await api(`/runs/${esc(state.selectedRun)}/cancel`,{});await refresh();}}));
  onForm('evalImportForm',async()=>{const raw=$('evalDatasetInput').value;if(new TextEncoder().encode(raw).length>2097152)throw new Error('Dataset exceeds 2 MiB');const s=await api('/suites',JSON.parse(raw));$('evalApproveId').value=s.id;status('Snapshot saved. Annotation approval is required before running it.');await refresh();});
  onForm('evalApproveForm',async()=>{await api(`/suites/${esc($('evalApproveId').value.trim())}/approve`,{note:$('evalApproveNote').value});$('evalApproveChecked').checked=false;status('Annotation approval recorded.');await refresh();});
  onForm('evalRunForm',async()=>{const r=await api('/runs',{suite_id:$('evalRunSuite').value,split:$('evalSplit').value,idempotency_key:$('evalRunKey').value});state.selectedRun=r.id;$('evalRunKey').value=newKey();status(`Run ${r.id} admitted. Request limits and permissions are checked again before dispatch.`);await refresh();});
  onForm('evalAccountForm',async()=>{if(!state.snapshot)throw new Error('Load settings first');await api('/settings',{version:state.snapshot.version,changes:values(state.fields)});renderSettings(await api('/settings'));status('Account settings saved. Node policy still applies.');});
  onForm('evalNodeForm',async()=>{if(!state.node||!isAdmin())throw new Error('Node administrator required');await api('/admin/settings',{version:state.node.version,changes:values(state.nodeFields)});await loadNode();renderSettings(await api('/settings'));status('Node policy saved through DamageBDD settings.');});
  onForm('evalReviewForm',async()=>{const item=state.review;if(!item)throw new Error('Choose a review item first');const note=$('evalReviewNote').value;
    if(item.kind==='suite')await api(`/suites/${esc(item.id)}/approve`,{owner:item.owner,note});
    else await api('/review',{owner:item.owner,id:item.id,task_id:item.task_id,verdict:$('evalReviewVerdict').value,note});
    state.review=null;showJSON('evalReviewDetail',{recorded:true});$('evalReviewNote').value='';status('Review recorded. Disagreement cannot be waived into a pass.');await loadReviews();});
  onForm('evalCompareForm',async()=>showJSON('evalComparison',await api('/compare',{baseline:$('evalBaseline').value.trim(),candidate:$('evalCandidate').value.trim(),baseline_target:$('evalBaselineTarget').value.trim(),candidate_target:$('evalCandidateTarget').value.trim()})));
  function reset() {
    state.epoch++;for(const c of state.controllers)c.abort();state.controllers.clear();state.loading=false;state.snapshot=null;state.node=null;state.selectedRun=null;state.runData=null;state.review=null;state.fields.clear();state.nodeFields.clear();
    for(const id of ['evalRunList','evalSuiteList','evalReviewList','evalReviewDetail','evalAccountFields','evalNodeFields','evalEffective','evalSuiteDetail','evalTrial','evalCases','evalTargets','evalMetrics','evalFindings','evalComparison'])$(id).replaceChildren();
    for(const form of root.querySelectorAll('form'))form.reset();$('evalRunSuite').replaceChildren();$('evalDatasetInput').value='';$('evalRunKey').value=newKey();$('evalReportPanel').hidden=true;status();accessChanged();
  }
  function setVisible(visible) {state.visible=visible;accessChanged();if(visible&&managedSession())void act(refresh);}
  state.timer=setInterval(()=>{if(state.visible&&!document.hidden&&managedSession())void act(refresh);},5000);
  function dispose(){state.disposed=true;clearInterval(state.timer);reset();}
  reset();return {refresh,reset,accessChanged,setVisible,dispose};
}
