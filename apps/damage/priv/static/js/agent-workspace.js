import {controlsFor, isTerminal, budgetLabel} from './agent-tasks.js';
import {mountBddRouting} from './bdd-routing.js';

export const EXAMPLES = {
  review: 'Review the configured code snapshot for correctness and failure handling. Cite source evidence, separate confirmed defects from hypotheses, and do not modify or publish anything.',
  explain: 'Explain the configured code review and patch. Describe each finding, its impact and the evidence behind it. Do not apply changes.',
  docs: 'Draft documentation for the configured source snapshot. Explain behaviour, prerequisites and failure modes. Mark uncertainty; do not publish.',
  monitor: 'Monitor the approved behaviour contract until its configured acceptance assertions pass. Stay within its time and monetary limits.'
};
export const needsAttention = t => ['awaiting_approval','interrupted','accounting_pending','cancelled_unreconciled','failed'].includes(t.status);
export const matchesFilter = (t, f) => f==='attention' ? needsAttention(t) : f==='active' ? !isTerminal(t.status) : f==='finished' ? isTerminal(t.status) : true;
export const canStartDraft = (d, goal, template, reviewed) => !!(d?.complete && d.validation?.valid === true &&
  d.policy_hash && d.goal === goal && d.template === template && reviewed && !(d.missing_steps?.length));
export const statusLabel = s => String(s || 'unknown').replaceAll('_',' ');

// Default adapter for DamageBDD. ECAI injects its existing auth-aware request
// function so managed-session restrictions and identity epochs remain intact.
export function workspaceRequest(authHeaders = () => ({})) {
  return async (path, options={}) => {
    const headers={Accept:'application/json',...await authHeaders(),...options.headers};
    const opts={...options,headers,credentials:'same-origin',mode:'same-origin',redirect:'error',cache:'no-store'};
    if(Object.hasOwn(options,'body')){opts.body=JSON.stringify(options.body);headers['content-type']='application/json';}
    const response=await fetch(path,opts);let body;
    try{body=await response.json();}catch{throw new Error(`Unreadable response (HTTP ${response.status}).`);}
    if(!response.ok){const e=new Error(body.message || ({forbidden:'This account is not enabled for agents.',same_origin_required:'This dashboard origin is not approved in the node’s agent configuration.',policy_changed:'The template policy changed. Review the objective again before starting.',agent_service_unavailable:'Agent service unavailable. Check node configuration.',admin_bearer_required:'A server-authorised administrator session is required.'}[body.error]) || String(body.error || `HTTP ${response.status}`));e.status=response.status;e.body=body;throw e;}
    return body;
  };
}

export function mountAgentWorkspace(root,{request, canUse=()=>true, intervalMs=4000}={}) {
  if(!root) return {setVisible(){},reset(){},dispose(){}};
  const $=name=>root.querySelector(`[data-agent="${name}"]`), form=$('compose');
  const prompt=form.elements.prompt, select=form.elements.template;
  const life=new AbortController();let controller=new AbortController();
  let visible=false,disposed=false,epoch=0,busy=false,polling=false,loading=false,timer=null;
  let templates=[],tasks=[],selected=null,current=null,draft=null,creation=null,job=null;
  const routing=mountBddRouting(root.querySelector('[data-bdd-routing]'),{request});
  const message=(text,bad=false)=>{$('message').textContent=text;$('message').dataset.error=String(bad);};
  const errorText=e=>e.body?.message || e.message || e.body?.error || 'Request failed.';
  const alive=t=>!disposed && t===epoch;
  async function api(path,options={}) {
    const timeout = new AbortController();
    const timerId = setTimeout(()=>timeout.abort(),path==='/api/agents/draft' ? 320000 : 30000);
    const signal = AbortSignal.any([controller.signal, timeout.signal, ...(options.signal ? [options.signal] : [])]);
    try { return await request(path,{...options,headers:{'x-damage-agent':'1','x-damage-bdd':'1',...options.headers},signal}); }
    catch(error) {
      if(timeout.signal.aborted)throw new Error('Request timed out. Its server-side outcome is not confirmed.');
      throw error;
    } finally {clearTimeout(timerId);}
  }
  const text=(tag,value,cls='')=>{const e=document.createElement(tag);e.textContent=String(value);if(cls)e.className=cls;return e;};
  const button=(label,fn)=>{const b=text('button',label);b.type='button';b.disabled=busy;b.addEventListener('click',fn,{signal:life.signal});return b;};
  function controls(){
    const bytes=new TextEncoder().encode(prompt.value).length,allowed=canUse() && templates.length>0;
    $('count').textContent=`${bytes} / 8000 bytes`;
    $('generate').disabled=busy || !allowed || !prompt.value.trim() || bytes>8000;
    $('manual').disabled=busy || !allowed || !select.value || !prompt.value.trim() || bytes>4096;
    $('cancel-draft').hidden=!job; $('cancel-draft').disabled=!!job?.cancelling;
    $('generate').textContent=job?'Drafting…':'Draft agent BDD';
    prompt.readOnly=busy;select.disabled=busy || !allowed;
    $('goal').readOnly=busy;
    $('recheck').disabled=busy || !select.value || !$('goal').value.trim();
    $('start').disabled=busy || !canStartDraft(draft,$('goal').value,select.value,$('reviewed').checked);
    $('download').disabled=busy || !draft?.feature || draft.goal!==$('goal').value || draft.template!==select.value;
    $('reviewed').disabled=busy || !draft?.validation?.valid || draft.goal!==$('goal').value || draft.template!==select.value;
    $('refresh').disabled=busy || !canUse();form.setAttribute('aria-busy',String(busy));
    $('controls').querySelectorAll('button').forEach(b=>b.disabled=busy);
  }
  function templateSummary(){
    const t=templates.find(t=>t.id===select.value);
    $('template-summary').textContent=t ? `${t.description} · ${t.skills.length} approved actions · execution planner: ${t.planner || 'operator configured'}.` : 'The model can suggest an approved template, never invent one. Choose a template to continue without AI.';
  }
  function renderPolicy(p){
    const box=$('policy');box.replaceChildren();if(!p)return;
    box.append(text('p',`Template: ${p.id} · execution planner: ${p.planner || 'operator configured'}`));
    box.append(text('p',`Allowed actions: ${p.skills.map(s=>`${s.id} (${s.effect}${s.approval ? ', approval required':''})`).join('; ')}`));
    box.append(text('p',`Verification: ${p.verification?.scope || 'See the operator template.'}`));
    const a=p.accounting;
    box.append(text('p',a?.mode==='aeternity' ? `Agent identity: ${a.agent_id}. Task ceiling: ${a.max_cost_units} DAMAGE base units. Fixed admission tariffs; AE fees and provider bills are separate.` : 'Accounting is disabled in this template. No on-chain settlement claim is made.'));
    if(p.limits)box.append(text('p',`Limits: ${p.limits.max_iterations} iterations · ${p.limits.max_llm_calls} planner calls · ${p.limits.max_wall_seconds}s task deadline.`));
  }
  function renderDraft(d){
    draft=d;select.value=d.template;$('goal').value=d.goal;$('review').hidden=false;$('reviewed').checked=false;
    $('feature').textContent=d.feature;renderPolicy(d.policy);templateSummary();
    $('draft-provenance').textContent=d.inference ? `Drafted with ${d.inference.provider} · ${d.inference.model} · route r${d.inference.routing_revision}. Not executed.` : 'Prepared without inference. Nothing has been started.';
    $('validation').textContent=d.validation?.valid ? 'Launch feature signatures checked. This does not verify the agent’s future output.' : 'Static validation failed. Do not start; check step availability and diagnostics.';
    const notes=$('notes');notes.replaceChildren();
    for(const n of d.assumptions || [])notes.append(text('p',`Assumption: ${n}`));
    for(const n of d.missing_steps || [])notes.append(text('p',`Unsupported requirement: ${n}`));
    for(const n of d.validation?.diagnostics || [])notes.append(text('p',n.message || 'Check this draft.'));
    if(!d.complete)notes.append(text('p','This request is not fully supported. Revise the objective or choose a different approved template.'));
    controls();
  }
  async function prepare(useModel){
    if(busy || !canUse())return;
    const ticket=epoch;busy=true;controls();message(useModel?'Drafting a bounded objective and launch BDD. Nothing will run until you start it.':'Checking the selected template and launch feature…');
    const id=crypto.randomUUID();
    if(useModel){job={id,controller:new AbortController(),started:Date.now(),tick:null};job.tick=setInterval(()=>{if(job?.id===id)message(`Drafting… ${Math.floor((Date.now()-job.started)/1000)}s elapsed. No task has been started.`);},1000);controls();}
    const activeJob=job;
    try{
      const d=useModel ? await api('/api/agents/draft',{method:'POST',body:{request_id:id,user_prompt:prompt.value.trim(),template:select.value},signal:activeJob.controller.signal})
        : await api('/api/agents/preview',{method:'POST',body:{template:select.value,goal:prompt.value.trim()}});
      if(!alive(ticket) || (useModel && (job!==activeJob || activeJob.cancelling)))return;
      renderDraft(d);message(d.complete ? 'Review the objective, BDD and limits below. Nothing has run.' : 'The draft contains unsupported requirements; revise it before starting.');
    }catch(e){if(alive(ticket) && e.name!=='AbortError')message(errorText(e),true);}
    finally{if(activeJob)clearInterval(activeJob.tick);if(alive(ticket) && (!useModel || (job===activeJob && !activeJob.cancelling))){job=null;busy=false;controls();}}
  }
  async function cancelDraft(){
    if(!job)return;const old=job;old.cancelling=true;old.controller.abort();clearInterval(old.tick);controls();
    const ticket=epoch;
    try{const r=await api('/ai/bdd/cancel',{method:'POST',body:{request_id:old.id}});if(alive(ticket))message(r.cancelled?'Draft cancelled. No task was started.':'No active draft was found. No task was started.');}
    catch(e){if(alive(ticket))message('Stopped waiting. Server cancellation was not confirmed; its generation deadline still applies.',true);}
    finally{if(alive(ticket)){job=null;busy=false;controls();}}
  }
  async function recheck(){
    if(busy || !select.value)return;const ticket=epoch;busy=true;controls();
    const same=draft?.goal===$('goal').value && draft?.template===select.value;
    const original=draft;
    try{const d=await api('/api/agents/preview',{method:'POST',body:{template:select.value,goal:$('goal').value}});
      if(!alive(ticket))return;
      if(same && original){d.assumptions=original.assumptions;d.missing_steps=original.missing_steps;d.complete=original.complete;d.inference=original.inference;}
      renderDraft(d);message('Objective checked against the current policy. Review again before starting.');
    }catch(e){if(alive(ticket)&&e.name!=='AbortError')message(errorText(e),true);}
    finally{if(alive(ticket)){busy=false;controls();}}
  }
  async function startTask(){
    if(busy || !canStartDraft(draft,$('goal').value,select.value,$('reviewed').checked))return;
    const payload={template:draft.template,goal:draft.goal,policy_hash:draft.policy_hash};
    const fingerprint=JSON.stringify(payload);
    if(!creation || creation.payload!==fingerprint)creation={payload:fingerprint,key:crypto.randomUUID()};
    const ticket=epoch;busy=true;controls();
    try{const task=await api('/api/agents/tasks',{method:'POST',headers:{'idempotency-key':creation.key},body:payload});
      if(!alive(ticket))return;creation=null;selected=task.id;$('reviewed').checked=false;
      message(`Task accepted: ${task.id}. Acceptance is not completion or settlement.`);
    }catch(e){if(alive(ticket)&&e.name!=='AbortError'){
      if(e.body?.error==='policy_changed') {draft={...draft,policy_hash:null};$('reviewed').checked=false;}
      message(`${errorText(e)} No acceptance confirmed. Retrying unchanged details reuses the same request key.`,true);
    }}
    finally{if(alive(ticket)){busy=false;controls();await refresh();}}
  }
  function renderTasks(){
    $('task-count').textContent=String(tasks.length);const list=$('tasks');list.replaceChildren();
    const shown=tasks.filter(t=>matchesFilter(t,$('filter').value)).sort((a,b)=>b.created_at-a.created_at);
    for(const t of shown){const b=button('',()=>{const ticket=epoch;selected=t.id;renderTasks();void details().catch(e=>{if(alive(ticket)&&e.name!=='AbortError')message(errorText(e),true);});});b.setAttribute('aria-pressed',String(t.id===selected));
      b.append(text('strong',`${t.template} · ${statusLabel(t.status)}`),text('small',`${t.id.slice(0,12)} · ${t.iteration || 0} iterations`));
      if(t.budget?.mode==='aeternity')b.append(text('small',`${t.budget.spent_units} / ${t.budget.max_cost_units} DAMAGE base units`));
      list.append(b);}
    if(!shown.length)list.append(text('p','No matching tasks. Describe a job to get started.','agent-muted'));
  }
  function renderTask(task,events){
    current=task;$('detail-section').hidden=false;$('detail-title').textContent=`${task.template} · ${statusLabel(task.status)}`;
    $('detail-summary').textContent=task.goal || task.id;$('budget').textContent=budgetLabel(task);
    $('receipt-state').textContent=`Execution: ${statusLabel(task.execution_status || task.status)}. Accounting: ${task.accounting_complete ? 'complete' : 'not confirmed complete'}. Receipt: ${statusLabel(task.receipt_state)}.`;
    $('detail').textContent=JSON.stringify(task,null,2);$('raw-events').textContent=JSON.stringify(events,null,2);
    $('proposal').textContent=task.pending ? JSON.stringify(task.pending,null,2) : 'No pending proposal.';
    $('proposal-section').open=task.status==='awaiting_approval';
    $('events').replaceChildren(...events.slice(-12).reverse().map(e=>text('p',`${statusLabel(e.kind)}${e.data?.reason ? ` · ${statusLabel(e.data.reason)}`:''}`)));
    const artifacts=new Map();for(const e of events){const a=e.kind==='action_succeeded' ? e.data?.result?.artifact : null;if(typeof a?.name==='string'&&typeof a?.content==='string')artifacts.set(a.name,a.content);}
    $('artifacts').replaceChildren(...Array.from(artifacts,([name,content])=>{const s=document.createElement('section');s.append(text('h4',name),text('pre',content));return s;}));
    if(!artifacts.size)$('artifacts').textContent='No generated artifact yet.';
    const names={learning:'Export ECAI candidate evidence',reconcile:'Reconcile accounting',approve:'Approve exact proposal',reject:'Reject proposal',pause:'Pause task',resume:'Resume task',cancel:'Cancel task'};
    $('controls').replaceChildren(...controlsFor(task.status,task).map(a=>button(names[a],()=>void command(a))));
  }
  async function details(){
    if(!selected)return;const id=selected,ticket=epoch;
    const [task,ev]=await Promise.all([api(`/api/agents/tasks/${encodeURIComponent(id)}`),api(`/api/agents/tasks/${encodeURIComponent(id)}/events`)]);
    if(alive(ticket)&&selected===id)renderTask(task,ev.events || []);
  }
  async function refresh(){
    if(!visible || disposed || !canUse() || polling)return;
    const ticket=epoch;polling=true;
    try{const r=await api('/api/agents/tasks');if(!alive(ticket))return;tasks=r.tasks || [];renderTasks();if(visible&&canUse())await details();}
    catch(e){if(alive(ticket)&&e.name!=='AbortError')message(errorText(e),true);}
    finally{if(alive(ticket))polling=false;}
  }
  function download(data,name,type='application/json'){
    const url=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  async function command(action){
    if(busy || !current)return;const ticket=epoch,task=current;
    if(action==='approve' && !window.confirm('Approve only the exact displayed proposal? External effects may not be reversible.'))return;
    if(action==='cancel' && !window.confirm('Cancel this task? Already-submitted external work and financial operations cannot be rolled back by cancelling.'))return;
    busy=true;controls();
    try{
      if(action==='learning'){const r=await api(`/api/agents/tasks/${encodeURIComponent(task.id)}/learning`);if(alive(ticket))download(JSON.stringify(r,null,2),`agent-${task.id}-candidate.json`);}
      else{await api(`/api/agents/tasks/${encodeURIComponent(task.id)}/command`,{method:'POST',body:{command:action,proposal_hash:task.pending?.hash || ''}});if(alive(ticket))message(`Command accepted: ${action}.`);}
    }catch(e){if(alive(ticket)&&e.name!=='AbortError')message(errorText(e),true);}
    finally{if(alive(ticket)){busy=false;controls();await refresh();}}
  }
  async function load(){
    if(!visible || disposed || loading){controls();return;}
    if(!canUse()){message('Sign in with a managed account to use agents. Wallet-only sessions cannot manage these tasks.');controls();return;}
    const ticket=epoch;loading=true;
    try{
      const r=await api('/api/agents/templates');if(!alive(ticket))return;templates=r.templates || [];
      const chosen=select.value;select.replaceChildren(new Option('Let the model suggest an approved template',''),...templates.map(t=>new Option(t.id,t.id)));
      if(templates.some(t=>t.id===chosen))select.value=chosen;templateSummary();controls();
      message(templates.length ? 'Choose an objective. AI drafting is optional; starting a task is always explicit.' : 'No approved templates. Ask the node operator to enable agent access and configure templates.');
      if(!visible)return;await routing.refresh();if(alive(ticket)&&visible)await refresh();
    }catch(e){if(alive(ticket)&&e.name!=='AbortError')message(errorText(e),true);}
    finally{if(alive(ticket))loading=false;}
  }
  async function poll(){
    clearTimeout(timer);const ticket=epoch;
    if(!visible || disposed || !canUse())return;
    if(!document.hidden&&!busy)await refresh();
    if(alive(ticket)&&visible&&canUse())timer=setTimeout(poll,intervalMs);
  }
  function invalidate(){ $('reviewed').checked=false;controls(); }
  form.addEventListener('submit',e=>{e.preventDefault();void prepare(true);},{signal:life.signal});
  prompt.addEventListener('input',controls,{signal:life.signal});
  prompt.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='Enter'&&!$('generate').disabled){e.preventDefault();form.requestSubmit();}},{signal:life.signal});
  select.addEventListener('change',()=>{templateSummary();invalidate();},{signal:life.signal});
  $('goal').addEventListener('input',invalidate,{signal:life.signal});$('reviewed').addEventListener('change',controls,{signal:life.signal});
  $('manual').addEventListener('click',()=>void prepare(false),{signal:life.signal});$('cancel-draft').addEventListener('click',()=>void cancelDraft(),{signal:life.signal});
  $('recheck').addEventListener('click',()=>void recheck(),{signal:life.signal});$('start').addEventListener('click',()=>void startTask(),{signal:life.signal});
  $('download').addEventListener('click',()=>{if(draft)download(draft.feature,'agent-task.feature','text/plain;charset=utf-8');},{signal:life.signal});
  $('refresh').addEventListener('click',()=>void refresh(),{signal:life.signal});$('filter').addEventListener('change',renderTasks,{signal:life.signal});
  root.querySelectorAll('[data-agent-example]').forEach(b=>b.addEventListener('click',()=>{if(busy)return;prompt.value=EXAMPLES[b.dataset.agentExample];controls();prompt.focus();},{signal:life.signal}));
  function reset(){epoch++;controller.abort();controller=new AbortController();if(job){job.controller.abort();clearInterval(job.tick);}job=null;busy=false;polling=false;loading=false;clearTimeout(timer);
    templates=[];tasks=[];selected=null;current=null;draft=null;creation=null;prompt.value='';select.replaceChildren(new Option('Let the model suggest an approved template',''));$('goal').value='';$('reviewed').checked=false;
    for(const n of ['tasks','detail','proposal','raw-events','events','artifacts','policy','notes','feature','detail-summary','detail-title','budget','receipt-state','draft-provenance','validation'])$(n).replaceChildren();
    $('task-count').textContent='0';$('detail-section').hidden=true;$('review').hidden=true;routing.reset();message('Sign in to manage your agents.');controls();}
  return {
    async setVisible(on){const changed=visible!==!!on;visible=!!on;if(!visible)clearTimeout(timer);if(visible&&changed){const ticket=epoch;await load();if(alive(ticket))void poll();}},
    async accessChanged(){if(visible){const ticket=epoch;await load();if(alive(ticket))void poll();}},
    reset,
    dispose(){disposed=true;visible=false;reset();life.abort();routing.dispose();}
  };
}
