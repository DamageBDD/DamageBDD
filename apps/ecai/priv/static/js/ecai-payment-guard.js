import {SCENARIOS, runScenario, createGateway, evidence, clone} from './payment-guard-model.js?v=payment-guard-v1';
const EMPTY=Object.freeze({setVisible(){},refresh(){},dispose(){}});
const MONEY=new Intl.NumberFormat('en-AU',{style:'currency',currency:'AUD',currencyDisplay:'code',maximumFractionDigits:2});
export function money(cents){return MONEY.format(cents/100).replace('AUD\u00a0','A$').replace('AUD ','A$');}
function el(tag,className='',text=''){const n=document.createElement(tag);n.className=className;n.textContent=text;return n;}
const STAGES=['01 · Invoice received','02 · Candidate proposed','03 · Policy checkpoint','04 · Ledger outcome'];
const TOUR=[
  ['A proposal is not permission','Start with Changed bank details. The invoice asks for a new account, but the trusted supplier record still names the original beneficiary. No real invoice or account is used.'],
  ['Compare the actual effects','The same scripted proposal enters three paths. The unguarded path writes to its mock ledger. Both guarded paths apply the same rules and show the same outcome. Valid payments have their own positive-control scenario.'],
  ['Challenge the boundary','Try an expired approval, a policy change after preview, or a duplicate request. Adjust the limit or clock and compare again. Playback explains the stored result; it never sends another payment.'],
  ['Check without trusting the presentation','Inspect the ledger and individual checks, then export evidence for the independent Python verifier. This public browser sandbox has no native index lookup, live model, real payment connector or remote DamageBDD execution.']
];
export function initPaymentGuard({visible=false}={}){
  if(typeof document==='undefined')return EMPTY;
  const root=document.getElementById('paymentGuard');if(!root)return EMPTY;
  const q=name=>root.querySelector(`[data-pg="${name}"]`);
  let selected='redirected',report=null,playing=false,timer=null,step=3,disposed=false,revision=0,tour=0;
  const handlers=[];
  const on=(node,type,fn)=>{node.addEventListener(type,fn);handlers.push(()=>node.removeEventListener(type,fn));};
  const set=(name,value)=>{q(name).textContent=value;};
  const options=()=>({limit_cents:Number(q('limit').value)*100,advance_minutes:Number(q('clock').value)});
  function explain(message){set('message',message);}
  function paintStep(value){
    step=Math.max(0,Math.min(3,Number(value)));q('position').value=String(step);set('stage-label',STAGES[step]);
    root.querySelectorAll('[data-pg-stage]').forEach(n=>n.dataset.active=String(Number(n.dataset.pgStage)===step));
  }
  function pause(){if(timer!==null)clearTimeout(timer);timer=null;playing=false;root.dataset.playing='false';set('play','▶ Replay decision');}
  function play(){
    if(!report||!visible||disposed)return;
    if(playing){pause();return;}
    if(window.matchMedia('(prefers-reduced-motion: reduce)').matches){explain('Reduced motion is enabled. Use the replay slider to explore each step without animation.');paintStep(0);return;}
    playing=true;root.dataset.playing='true';set('play','Ⅱ Pause replay');paintStep(0);
    const next=()=>{if(!playing||disposed||!visible||document.hidden){pause();return;}paintStep(step+1);if(step===3){pause();return;}timer=setTimeout(next,1200);};
    timer=setTimeout(next,1200);
  }
  function renderChecks(receipt){
    const box=q('checks');box.replaceChildren();
    for(const c of receipt.checks){const row=el('div','pg-check');row.append(el('span',c.pass?'pg-good':'pg-bad',c.pass?'✓':'×'));const text=el('div');text.append(el('b','',c.label),el('p','',c.detail));row.append(text);box.append(row);}
  }
  function renderLedger(){
    if(!report)return;
    const lane=report.lanes[q('ledger-path').value]||report.lanes.guarded;
    const totals=q('ledger-totals');totals.replaceChildren();
    for(const [label,value] of [['Opening balance',money(report.fixture.initial_balance_cents)],['Actual debits',money(report.fixture.initial_balance_cents-lane.balance_cents)],['Closing balance',money(lane.balance_cents)]]){const d=el('div','',label);d.append(el('strong','',value));totals.append(d);}
    const rows=q('ledger-rows');rows.replaceChildren();
    if(!lane.transfers.length){const tr=el('tr'),td=el('td','pg-empty','No debit executed. The opening balance is unchanged.');td.colSpan=5;tr.append(td);rows.append(tr);}
    for(const t of lane.transfers){const tr=el('tr');for(const value of [t.id,t.invoice_id,t.beneficiary,money(t.amount_cents),money(t.balance_after_cents)])tr.append(el('td','',value));rows.append(tr);}
    set('ledger-note',`${lane.transfers.length} new debit${lane.transfers.length===1?'':'s'} · ${lane.receipts.filter(r=>r.status==='replayed').length} returned receipt${lane.receipts.filter(r=>r.status==='replayed').length===1?'':'s'} · ${lane.receipts.filter(r=>r.status==='blocked').length} blocked request${lane.receipts.filter(r=>r.status==='blocked').length===1?'':'s'}. Only new debits change the balance.`);
  }
  function render(){
    const {fixture:f,lanes,acceptance}=report,g=lanes.guarded;
    root.dataset.stale='false';q('stale').hidden=true;
    set('prevented',money(lanes.unguarded.unauthorised_outflow_cents-g.unauthorised_outflow_cents));set('unsafe',money(g.unauthorised_outflow_cents));
    const eligible=lanes.unguarded.receipts.some(r=>r.authorised);
    set('eligible',eligible?`${g.transfers.length} / 1`:'Not eligible');set('eligible-note',eligible?'One eligible invoice. Retries are not new invoices.':'No payment is authorised under these settings.');
    set('pass',`${acceptance.filter(c=>c.pass).length} / ${acceptance.length} pass`);
    const blocked=g.receipts.filter(r=>r.status==='blocked'),paid=g.transfers.length;
    set('decision-badge',paid?blocked.length?'PAID ONCE · DUPLICATE BLOCKED':'PAYMENT AUTHORISED':'PAYMENT BLOCKED');
    q('decision-badge').className='pg-pill '+(paid?'pg-good':'pg-amber');
    set('invoice-summary',`${f.invoice.id} · ${money(f.invoice.amount_cents)} · Harbour Solar (fictional)`);
    set('proposal-summary',`${f.proposals.length} request${f.proposals.length===1?'':'s'} → ${f.proposals[0].beneficiary}`);
    set('gate-title',paid?'Authorise eligible debit':'Reject this proposal');
    set('gate-summary',blocked.length?blocked[0].checks.filter(c=>!c.pass).map(c=>c.label).join(' · '):'Current policy, bound approval and beneficiary checks pass.');
    set('ledger-title',paid?'One invoice. One debit.':'No funds moved.');set('ledger-summary',`${paid} new debit${paid===1?'':'s'} · closing balance ${money(g.balance_cents)}.`);
    set('invoice-text',f.note);
    q('records').replaceChildren();
    const records=[
      ['Supplier record · SUP-017 / revision 3',f.supplier?`Approved account ${f.supplier.beneficiary}${f.supplier.pending_beneficiary?'; proposed change '+f.supplier.pending_beneficiary:''}.`:'UNAVAILABLE · payment must fail closed.'],
      ['Payment policy · PAY-AUD-01',`Retrieved revision ${f.policy.revision}; execution revision ${f.policy.revision+(f.policy_changes_before_execution?1:0)}. AUD only · limit ${money(f.policy.limit_cents)}.`],
      ['Approval record · APR-204',`${f.approval.approvers.join(' + ')} · beneficiary ${f.approval.beneficiary} · ${f.clock<f.approval.expires_at?'valid at execution':'expired at execution'}.`],
      ['Invoice record · INV-1042',`${money(f.invoice.amount_cents)} · currency ${f.invoice.currency} · supplier ${f.invoice.supplier_id}.`]
    ];
    for(const [name,value] of records){const row=el('div','pg-record');row.append(el('strong','',name),el('span','',value));q('records').append(row);}
    const configs=[['unguarded','Scripted proposal, no gate','A deliberately unguarded fixture. Not a measured model failure rate.'],['conventional','Conventional rule guard','Same gate, same outcome. The comparison does not pretend conventional rules cannot verify.'],['guarded','ECAI workspace + guard','Adds the inspectable context, explanation and portable evidence shown here.']];
    q('lanes').replaceChildren();
    const max=Math.max(1,lanes.unguarded.unauthorised_outflow_cents);
    for(const [key,title,note] of configs){
      const lane=lanes[key],card=el('article','pg-lane'+(key==='guarded'?' pg-featured':''));
      card.append(el('small','',key==='guarded'?'EVIDENCE WORKSPACE':'COMPARISON PATH'),el('h3','',title),el('strong','pg-lane-amount '+(lane.unauthorised_outflow_cents?'pg-bad':'pg-good'),money(lane.unauthorised_outflow_cents)),el('small','','Unauthorised test outflow'));
      const bar=el('div','pg-lane-bar'),fill=el('i');fill.style.setProperty('--pg-width',`${lane.unauthorised_outflow_cents/max*100}%`);bar.append(fill);card.append(bar);
      const list=el('dl');for(const [k,v] of [['New debits',lane.transfers.length],['Blocked requests',lane.receipts.filter(r=>r.status==='blocked').length],['Returned receipts',lane.receipts.filter(r=>r.status==='replayed').length],['Closing balance',money(lane.balance_cents)]])list.append(el('dt','',k),el('dd','',String(v)));
      card.append(list,el('p','',note));q('lanes').append(card);
    }
    q('attempt').replaceChildren();g.receipts.forEach((r,i)=>{const o=el('option','',`${i+1}. ${r.idempotency_key} · ${r.status.toUpperCase()}`);o.value=String(i);q('attempt').append(o);});
    const initial=blocked.length?g.receipts.findIndex(r=>r.status==='blocked'):0;q('attempt').value=String(initial);renderChecks(g.receipts[initial]);
    q('acceptance').replaceChildren();for(const c of acceptance){const row=el('div','pg-check');row.append(el('span',c.pass?'pg-good':'pg-bad',c.pass?'✓':'×'),el('b','',c.label));q('acceptance').append(row);}
    renderLedger();paintStep(3);q('export').disabled=false;q('play').disabled=false;q('position').disabled=false;
  }
  function invalidate(){
    revision++;pause();report=null;root.dataset.stale='true';q('stale').hidden=false;
    for(const name of ['prevented','unsafe','eligible','pass'])set(name,'—');
    q('acceptance').replaceChildren();q('export').disabled=true;q('play').disabled=true;q('position').disabled=true;set('challenge-result','');set('limit-value',money(options().limit_cents));explain('Settings changed. Compare payment paths to check the new policy.');
  }
  function run(){
    if(disposed)return;pause();revision++;
    try{report=runScenario(selected,options());render();set('challenge-result','');explain(`${SCENARIOS.find(s=>s.id===selected).title}: comparison ready. ${report.lanes.guarded.transfers.length} guarded mock debit(s). No real funds or network calls.`);}catch(e){invalidate();explain(e.message);}
  }
  function choose(id){
    selected=id;q('limit').value='5000';q('clock').value='0';q('ledger-path').value='guarded';set('limit-value',money(500000));
    root.querySelectorAll('[data-pg-scenario]').forEach(n=>n.setAttribute('aria-pressed',String(n.dataset.pgScenario===id)));run();
  }
  for(const [i,s] of SCENARIOS.entries()){
    const b=el('button','pg-scenario');b.type='button';b.dataset.pgScenario=s.id;b.setAttribute('aria-pressed',String(s.id===selected));b.setAttribute('title',s.description);
    b.append(el('small','',`${String(i+1).padStart(2,'0')} / ${s.tag}`),el('strong','',s.title),el('span','',s.description));q('scenarios').append(b);on(b,'click',()=>choose(s.id));
  }
  on(q('run'),'click',run);on(q('reset'),'click',()=>choose('redirected'));
  on(q('limit'),'input',invalidate);on(q('clock'),'change',invalidate);
  on(q('ledger-path'),'change',renderLedger);on(q('attempt'),'change',()=>{if(report)renderChecks(report.lanes.guarded.receipts[Number(q('attempt').value)]);});
  on(q('play'),'click',play);on(q('position'),'input',()=>{pause();paintStep(q('position').value);});
  on(q('tamper'),'click',()=>{const candidateReport=runScenario(selected,options()),g=createGateway(candidateReport.fixture),p=clone(candidateReport.fixture.proposals[0]);p.approved=true;const receipt=g.submit(p);set('challenge-result',`${receipt.status==='blocked'?'Rejected':'Unexpected result'}: a forged approved=true field is not trusted authority. ${g.snapshot().transfers.length} new mock debits. The displayed run is unchanged.`);});
  on(q('suite'),'click',()=>{const runs=SCENARIOS.map(s=>runScenario(s.id));const checks=runs.flatMap(r=>r.acceptance);set('challenge-result',`${runs.length} / ${runs.length} scenarios replayed · ${checks.filter(c=>c.pass).length} / ${checks.length} local acceptance checks pass at reference settings. These are executable local checks, not remote DamageBDD results.`);});
  on(q('export'),'click',async()=>{
    if(!report||disposed)return;const snapshot=report,epoch=revision;q('export').disabled=true;
    try{const output=await evidence(snapshot);if(disposed||revision!==epoch||!report)return;
      const url=URL.createObjectURL(new Blob([JSON.stringify(output,null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=`payment-guard-${selected}.evidence.json`;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);explain('Evidence exported. The SHA-256 digest is a checksum, not a signature. Run the independent Python verifier to reconstruct this fixture.');
    }catch(e){if(!disposed&&revision===epoch)explain(e.message);}finally{if(!disposed&&revision===epoch&&report)q('export').disabled=false;}
  });
  function tourPaint(){set('tour-counter',`${String(tour+1).padStart(2,'0')} OF 04`);set('tour-title',TOUR[tour][0]);set('tour-text',TOUR[tour][1]);set('tour-next',tour===3?'Start exploring ✓':'Next →');q('tour-back').disabled=tour===0;}
  on(q('tour-open'),'click',()=>{pause();tour=0;tourPaint();if(!q('tour').open)q('tour').showModal();});
  on(q('tour-next'),'click',()=>{if(tour===3){q('tour').close();return;}tour++;tourPaint();});on(q('tour-back'),'click',()=>{tour=Math.max(0,tour-1);tourPaint();});
  const presentationLabel=()=>set('present',document.fullscreenElement===root||root.dataset.present==='true'?'Exit presentation ⛶':'Presentation mode ⛶');
  on(q('present'),'click',async()=>{
    if(document.fullscreenElement===root){await document.exitFullscreen();}
    else if(root.dataset.present==='true')root.dataset.present='false';
    else{try{await root.requestFullscreen();}catch{root.dataset.present='true';}}
    presentationLabel();
  });
  on(document,'fullscreenchange',presentationLabel);on(document,'keydown',e=>{if(e.key==='Escape'){root.dataset.present='false';presentationLabel();}});
  on(document,'visibilitychange',()=>{if(document.hidden)pause();});
  run();
  return Object.freeze({
    setVisible(value){visible=!!value;if(!visible){pause();if(q('tour').open)q('tour').close();root.dataset.present='false';}},
    refresh(){if(!disposed)run();},
    dispose(){disposed=true;revision++;pause();if(q('tour').open)q('tour').close();root.dataset.present='false';handlers.splice(0).forEach(fn=>fn());}
  });
}
