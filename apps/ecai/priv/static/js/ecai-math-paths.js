import {MATH_SAMPLES} from './ecai-math-samples.js?v=math-samples-v1';
import {curveInvariants, tracePoint, scalarPoint, sageScript, realCurvePlot} from './ecai-math-exact.js?v=math-samples-v1';
/* Exact path inspector. The server checks mathematics; the browser renders data.
 * No JSON receipt is trusted as evidence until the API has replayed it. */
export function rationalInput(value) {
  const match = /^(-?\d+)(?:\/(\d+))?$/.exec(String(value).trim());
  if (!match || match[1].length > 64 || (match[2] || '1').length > 64)
    throw new Error('Use an integer or fraction with at most 64 digits per component.');
  const denominator = match[2] || '1';
  if (BigInt(denominator) === 0n) throw new Error('A rational denominator cannot be zero.');
  return [match[1], denominator];
}
export function polynomial(coefficients) {
  const terms = [];
  for (let i = coefficients.length - 1; i >= 0; i--) {
    const [ns, ds] = coefficients[i];
    const n = BigInt(ns), d = BigInt(ds);
    if (n === 0n) continue;
    const abs = n < 0n ? -n : n;
    const c = d === 1n ? `${abs}` : `(${abs}/${d})`;
    const power = i === 0 ? '' : i === 1 ? 'x' : i === 2 ? 'x²' : i === 3 ? 'x³' : `x^${i}`;
    const term = (i && abs === d ? '' : c) + power;
    terms.push((terms.length ? (n < 0n ? ' − ' : ' + ') : n < 0n ? '−' : '') + term);
  }
  return terms.join('') || '0';
}
export function curveEquation(curve) {
  return 'y² = ' + polynomial([curve.a6, curve.a4, curve.a2, ['1', '1']]);
}

export function initMathPaths({request, currentToken, managedSession, openLogin, toast, sampleSearch = globalThis.location?.search || ''}) {
  const root = document.querySelector('[data-panel="math"]');
  if (!root) return {reset(){}, refresh:async()=>{}, setVisible(){}, accessChanged(){}, dispose(){}};
  const $ = (id) => document.getElementById(id);
  let visible = false, disposed = false, epoch = 0, readSerial = 0, selectionSerial = 0;
  let timer = null, reader = null, selectedId = '', selected = null, jobs = [], submitting = false;
  let selection = {kind:'curve', index:0}, activeRowId = '';
  let sampleId = initialSample();
  const listeners = [], downloads = new Set();
  const node = (tag, cls = '', value) => {
    const e = document.createElement(tag); if (cls) e.className = cls;
    if (value !== undefined) e.textContent = String(value); return e;
  };
  const put = (id, text) => { $(id).textContent = String(text); };
  const on = (e, type, fn) => { e.addEventListener(type, fn); listeners.push([e,type,fn]); };
  const pretty = (x) => JSON.stringify(x, null, 2);
  const allowed = () => !disposed && managedSession();
  const writable = () => allowed() && Boolean(currentToken());
  const payload = (r) => { if (r?.ok !== true) throw new Error('Unexpected mathematical API response.'); return r.data; };
  const short = (s) => s ? `${String(s).slice(0,8)}…${String(s).slice(-6)}` : 'Not supplied';
  const date = (ms) => Number.isSafeInteger(ms) ? new Date(ms).toLocaleString() : 'Not recorded';
  const message = (error) => error?.body?.error ? String(error.body.error) : error?.message || 'Request failed';
  const stopPoll = () => { if (timer !== null) clearTimeout(timer); timer = null; };
  function schedule() {
    stopPoll();
    if (visible && !document.hidden && allowed() && jobs.some(j => j.status === 'running'))
      timer = setTimeout(() => void refresh(), 1500);
  }
  function activeRow() {
    return selected?.result?.exploration?.results?.find(r => r.model_id === activeRowId) || null;
  }
  function activeResult() {
    const r = selected?.result;
    if (!r?.exploration) return r || null;
    const row = activeRow();
    if (!row) return null;
    return {...r, path:JSON.parse(row.path_json), path_json:row.path_json,
      artifact_sha256:row.artifact_sha256, comparison:row.comparison_to_source,
      classCertificate:row.class_certificate, localClass:row.local_class};
  }
  function questionMode() {
    const explore=$('mathMode').value==='explore';
    $('mathTargetFields').hidden=explore; $('mathTargetFields').disabled=explore;
    const limit=$('mathDiscoverForm').elements.namedItem('max_curves');
    limit.max=explore?'32':'64';
    if(Number(limit.value)>Number(limit.max))limit.value=limit.max;
    $('mathTimeBudget').hidden=!explore;
    $('mathDiscoverForm').elements.namedItem('timeout_ms').disabled=!explore;
    put('mathBuildTitle',explore?'Explore from one curve over Q':'Find a connection over Q');
    put('mathDiscover',explore?'Explore from source →':'Discover & verify →');
    put('mathQuestionHint',explore?'Which models can we reach, and which are non-isomorphic to the source over Q?':'Find a checked degree-2 transformation path between the two given models.');
  }
  function controls() {
    const canWrite = writable() && !submitting;
    const r = activeResult(), canInspect = Boolean((selected?.preview || allowed()) && r?.path);
    for (const id of ['mathDiscover','mathDemo','mathImportFile']) $(id).disabled = !canWrite;
    $('mathImport').disabled = !canWrite || !$('mathImportFile').files?.length;
    $('mathReplay').disabled = !canWrite || selected?.status !== 'succeeded' || !r?.path_json;
    for (const id of ['mathExport','mathBundle']) $(id).disabled = !canInspect || !r?.path_json;
    $('mathExploreExport').disabled = !allowed() || !selected?.result?.exploration_json;
    $('mathRefresh').disabled = !allowed() || submitting;
    $('mathSampleVerify').disabled = submitting;
    $('mathSampleVerify').textContent = !writable() ? 'Sign in to verify on node' : currentSample().expected === 'reject' ? 'Test expected rejection' : 'Verify this example on node';
    for (const id of ['mathPointEvaluate','mathPointMultiply','mathSageExport']) $(id).disabled = !canInspect;
  }
  function reportError(error) {
    if (error?.name === 'AbortError') return;
    let text = message(error);
    if (error?.status === 429) text += ' — wait for the active job or retry shortly.';
    if (error?.status === 503) text += ' — check math_dashboard_enabled and restart the ECAI service.';
    put('mathNotice', text); toast?.(text, true);
  }
  function facts(rows) {
    const dl = node('dl','math-facts');
    for (const [label, value] of rows) dl.append(node('dt','',label), node('dd','',value));
    return dl;
  }
  function rawDetails(title, value) {
    const d = node('details'); d.append(node('summary','',title), node('pre','math-json',pretty(value))); return d;
  }
  function clearPath() {
    $('mathPointResult').replaceChildren(); $('mathPointResult').className='math-point-result'; put('mathScalarResult','');
    $('mathExploration').hidden=true; $('mathExploreResults').replaceChildren(); $('mathExploreMetrics').replaceChildren(); put('mathExploreScope','');
    $('mathMetrics').replaceChildren();
    $('mathGraph').replaceChildren(node('div','empty-state','Run a discovery or import a path to see its exact curve models and maps.'));
    put('mathInspectorTitle','Select an object');
    $('mathInspectorBody').replaceChildren(node('p','context-hint','Equations, exact coefficients and replay checks appear here.'));
    put('mathChecks','No verification evidence loaded.'); put('mathSearch','No search data loaded.'); put('mathRun','No run selected.');
  }
  function reset() {
    epoch++; readSerial++; selectionSerial++; stopPoll(); reader?.abort(); reader = null;
    selectedId = ''; selected = null; jobs = []; submitting = false; activeRowId='';
    $('mathNonIsoOnly').checked=false;
    $('mathDiscoverForm').reset(); questionMode();
    $('mathImportFile').value = ''; clearPath(); renderJobs();
    put('mathStatus','No path loaded'); $('mathStatus').className = 'status-tag';
    loadSample(sampleId); controls();
  }
  function renderJobs() {
    const host = $('mathJobs'); host.replaceChildren();
    if (!jobs.length) { host.append(node('div','empty-state','No retained jobs for this account.')); return; }
    for (const j of jobs) {
      const b = node('button','math-job-row'); b.type = 'button'; b.dataset.jobId = j.id;
      b.setAttribute('aria-current', String(j.id === selectedId));
      const copy = node('span','math-job-copy');
      copy.append(node('strong','',`${j.operation} · ${date(j.created_at_ms)}`), node('small','',j.id));
      b.append(copy,node('span','status-tag',j.status)); host.append(b);
    }
  }
  function renderInspector() {
    const path = activeResult()?.path; if (!path) return;
    const host = $('mathInspectorBody'); host.replaceChildren();
    if (selection.kind === 'curve') {
      const i = selection.index, c = i === 0 ? path.source : path.steps[i-1].map.codomain;
      const id = i === 0 ? path.verification.source_id : path.verification.steps[i-1].target_id;
      put('mathInspectorTitle', `E${i} · ${i === 0 ? 'Source' : i === path.hops ? 'Target' : 'Intermediate'}`);
      host.append(node('pre','math-formula',curveEquation(c)));
      try {
        const inv=curveInvariants(c);
        host.append(facts([['Field','Q · exact rationals'],['j-invariant',inv.j],['Model discriminant',inv.discriminant],['c₄',inv.c4],['c₆',inv.c6]]),realCurvePlot(document,c));
      } catch(error) { host.append(node('p','context-hint',message(error))); }
      host.append(rawDetails('Exact coefficients and model ID',{model_id:id,a2:c.a2,a4:c.a4,a6:c.a6}),
        node('p','context-hint','This ID denotes an exact model, not its entire isomorphism class. Model discriminants need not be minimal discriminants.'));

    } else {
      const i = selection.index, step = path.steps[i], m = step.map, check = path.verification.steps[i];
      put('mathInspectorTitle',`φ${i+1} · E${i} → E${i+1}`);
      host.append(node('pre','math-formula',`X = (${polynomial(m.x_num)}) / (${polynomial(m.x_den)})\nY = y · (${polynomial(m.y_num)}) / (${polynomial(m.y_den)})`), facts([
        ['Degree',m.degree],['Edge weight (not currency)',step.cost],['Map ID',check.map_id],
        ['Polynomial identity',check.polynomial_identity],['Degree checked',check.degree_checked],
        ['Origin preserved',check.origin_preserved],['Checker',check.checker],
        ['Source labels (not authenticated)',step.origins.join('; ') || 'None']
      ]),rawDetails('Exact coefficients',m));
    }
  }
  function highlightSelection() {
    for (const b of $('mathGraph').querySelectorAll('button'))
      b.setAttribute('aria-pressed', String(b.dataset.kind === selection.kind && Number(b.dataset.index) === selection.index));
    renderInspector();
  }
  function renderPath() {
    const p = activeResult().path;
    $('mathMetrics').replaceChildren();
    for (const [label,value] of [['Curve occurrences',p.hops+1],['Transformations',p.hops],['Composite degree',p.total_degree],['Edge-weight sum',p.total_cost]]) {
      const card = node('div','math-metric'); card.append(node('span','',label),node('strong','',value)); $('mathMetrics').append(card);
    }
    const graph = $('mathGraph'); graph.replaceChildren();
    const curves = [p.source, ...p.steps.map(s => s.map.codomain)];
    for (let i = 0; i < curves.length; i++) {
      const c = curves[i], id = i === 0 ? p.verification.source_id : p.verification.steps[i-1].target_id;
      const b = node('button','math-node'); b.type = 'button'; b.dataset.kind='curve'; b.dataset.index=String(i);
      b.setAttribute('aria-label',`Inspect curve E${i}: ${curveEquation(c)}`);
      b.append(node('small','',i===0?'SOURCE':i===curves.length-1?'TARGET':'INTERMEDIATE'), node('strong','',`E${i}`),
        node('span','math-equation',curveEquation(c)),node('small','',short(id))); graph.append(b);
      if (i < p.steps.length) {
        const e=node('button','math-edge'); e.type='button'; e.dataset.kind='map'; e.dataset.index=String(i);
        e.setAttribute('aria-label',`Inspect map ${i+1}, degree ${p.steps[i].map.degree}`);
        e.append(node('span','math-edge-title',`φ${i+1} · degree ${p.steps[i].map.degree}`),node('span','math-arrow','⟶'),node('small','',selected.preview ? 'Candidate' : 'Checked')); graph.append(e);
      }
    }
    if (selection.index >= curves.length || (selection.kind==='map' && selection.index >= p.steps.length)) selection={kind:'curve',index:0};
    highlightSelection();
  }
  function renderEvidence() {
    const r=activeResult(), p=r.path, host=$('mathChecks'); host.replaceChildren();
    const checkRow=(label,value,good=false)=>{const row=node('div','math-check-row');row.append(node('span','',label),node('strong',good?'':'math-unattached',value));host.append(row);};
    checkRow('Native algebra replay',`${p.verification.status} · ${p.hops} maps`,p.verification.status==='verified');
    checkRow('Native path identity','Checked by the Erlang verifier',true);
    checkRow('Formal proof-assistant certificate','Not provided');
    checkRow('Independent Python check','Not attached to this job');
    checkRow('DamageBDD feature report','Not attached to this job');
    checkRow('Source/provenance authentication','Not established by algebraic verification');
    host.append(rawDetails('Native verification receipt',p.verification));
    if (r.comparison) {
      checkRow('Q-isomorphism to source',r.comparison.relation==='non_isomorphic'?'Proved non-isomorphic':'Checked isomorphism',true);
      host.append(rawDetails('Source-comparison certificate',r.comparison),rawDetails('Local class certificate',r.classCertificate));
    }
    const search=$('mathSearch'); search.replaceChildren();
    if (selected.result.exploration) {
      const e=selected.result.exploration;
      search.append(facts([['Stop reason',e.stop_reason],['Completed within declared bounds',e.completed_within_declared_bounds],['Global completeness','Not claimed'],...Object.entries(e.stats)]),rawDetails('Exploration budget',e.bounds));
    }
    else if (p.search) search.append(facts(Object.entries(p.search)));
    else search.append(node('p','context-hint','No trusted search counters are available for this path. Import and replay do not authenticate submitted search history.'));
    if (r.metadata?.generation_bounds) search.append(rawDetails('Kernel-discovery bounds',r.metadata.generation_bounds));
    if (p.bounds) search.append(rawDetails('Path-search bounds',p.bounds));
    search.append(node('p','context-hint','No search-event trace was recorded. Only the returned path is drawn; no other branches or discovery animation are invented.'));
    const run=$('mathRun'); run.replaceChildren(facts([
      ['Dashboard job',selected.id],['Operation',selected.operation],['Created',date(selected.created_at_ms)],
      ['Checked',date(r.checked_at_ms)],['Math task elapsed',`${r.elapsed_ms} ms (includes verification and encoding; excludes HTTP)`],
      ['Output JSON SHA-256',r.artifact_sha256],['Path ID',p.id],['Replay of job',selected.replayed_job_id || 'Not a replay'],
      ['Selected model',activeRowId || 'Single path'],['Replayed model',selected.replayed_model_id || 'Not selected'],
      ['Input SHA-256',r.metadata?.input_sha256 || 'Generated on this node'],['Retention',selected.retention]
    ]));
    run.append(node('p','context-hint','This is a dashboard-native run, not a DamageBDD feature execution. No report CID, release attestation, payment or settlement is inferred.'),node('p','context-hint',r.metadata?.note || ''));
  }
  function renderExploration() {
    const e=selected?.result?.exploration;
    $('mathExploration').hidden=!e;
    if (!e) return;
    const summary=e.summary;
    put('mathExploreScope', e.completed_within_declared_bounds
      ? 'Finished within the declared coordinate and depth bounds. This is not a complete isogeny class or a claim of new mathematics.'
      : `Stopped: ${e.stop_reason}. Retained paths are checked; the exploration is incomplete.`);
    const metrics=$('mathExploreMetrics'); metrics.replaceChildren();
    for (const [label,value] of [['Retained models (incl. source)',summary.retained_models],['Non-isomorphic to source',summary.non_isomorphic_to_source_models],['Local Q-isomorphism classes',summary.local_q_classes],['Other classes found',summary.non_source_q_classes]]) {
      const card=node('div','math-metric');card.append(node('span','',label),node('strong','',value));metrics.append(card);
    }
    const results=$('mathExploreResults');results.replaceChildren();
    for (const row of e.results) {
      const nonIso=row.comparison_to_source.relation==='non_isomorphic';
      if ($('mathNonIsoOnly').checked && !nonIso) continue;
      const b=node('button','math-explore-row'); b.type='button'; b.dataset.modelId=row.model_id;
      b.setAttribute('aria-pressed',String(row.model_id===activeRowId));
      const copy=node('span','math-explore-copy');
      copy.append(node('strong','',curveEquation(row.curve)),node('small','',`Class ${row.local_class} · ${row.depth} hops · ${short(row.model_id)}`));
      b.append(copy,node('span',nonIso?'math-relation-different':'math-relation-same',row.depth===0?'Source model':nonIso?'Non-isomorphic over Q':'Isomorphic to source'));
      results.append(b);
    }
    if (!results.childElementCount) results.append(node('p','context-hint','No retained model meets this filter. This is not proof that no such model exists.'));
  }
  function renderSelected() {
    renderJobs();
    if (selected?.preview) { renderExploration(); renderPath(); renderPreviewEvidence(); controls(); return; }
    if (!selected) { clearPath(); controls(); return; }
    put('mathPathTitle',`Node job · ${short(selected.id)}`);
    const expedition=selected.result?.exploration;
    if (expedition && !expedition.results.some(r=>r.model_id===activeRowId))
      activeRowId=(expedition.results.find(r=>r.comparison_to_source.relation==='non_isomorphic') || expedition.results[0])?.model_id || '';
    put('mathStatus',selected.status === 'succeeded' ? (expedition ? (expedition.completed_within_declared_bounds?'Bounded exploration complete':'Partial exploration · checked paths'):'Algebraically verified') : selected.status);
    $('mathStatus').className='status-tag '+(selected.status==='succeeded'?(expedition&&!expedition.completed_within_declared_bounds?'math-status-running':'math-status-good'):selected.status==='failed'?'math-status-failed':'math-status-running');
    if (selected.status==='succeeded' && activeResult()?.path) {
      renderExploration(); renderPath(); renderEvidence();
      put('mathNotice',expedition ? 'Select any retained model to inspect its path. Source-comparison and class certificates are separate from path verification.' : 'Exact mathematical checks passed for the selected artifact. Verification scope and provenance are shown separately below.');
    } else {
      clearPath();
      put('mathNotice',selected.status==='failed' ? `Job failed: ${selected.error || 'Unknown error'}. A bounded search failure does not prove that no relationship exists.` : 'The node is computing this job. No verification claim is made until it completes.');
      $('mathRun').replaceChildren(facts([['Dashboard job',selected.id],['Created',date(selected.created_at_ms)],['State',selected.status]]));
    }
    controls();
  }
  async function selectJob(id) {
    const e=epoch, serial=++selectionSerial; selectedId=id; selected=null; activeRowId=''; selection={kind:'curve',index:0}; $('mathPointPresets').replaceChildren(); clearPath(); renderJobs(); controls();
    put('mathStatus','Loading job'); $('mathStatus').className='status-tag';
    try {
      const job=payload(await request(`/ecai/math/jobs/${encodeURIComponent(id)}`));
      if (disposed || e!==epoch || serial!==selectionSerial || selectedId!==id) return;
      selected=job; renderSelected(); schedule();
    } catch (err) { if(e===epoch && serial===selectionSerial) reportError(err); }
  }
  async function refresh() {
    if (disposed || !visible || document.hidden) return;
    if (!allowed()) { controls(); if(!selected?.preview)put('mathNotice','Sign in with a managed account to use mathematical jobs.'); return; }
    const e=epoch, serial=++readSerial, selSerial=selectionSerial;
    reader?.abort(); const controller=new AbortController(); reader=controller;
    try {
      const list=payload(await request('/ecai/math/jobs',{signal:controller.signal}));
      if(e!==epoch || serial!==readSerial || disposed) return;
      jobs=list; renderJobs();
      if (!selectedId && jobs.length && !selected?.preview) { await selectJob(jobs[0].id); }
      else if (selectedId && jobs.some(j=>j.id===selectedId)) {
        const id=selectedId;
        const job=payload(await request(`/ecai/math/jobs/${encodeURIComponent(id)}`,{signal:controller.signal}));
        if(e!==epoch || serial!==readSerial || selSerial!==selectionSerial || selectedId!==id || disposed) return;
        // Avoid rebuilding focused inspectors on every poll of an unrelated job.
        if (!selected || selected.status!==job.status) { selected=job; renderSelected(); }
      } else if (selectedId && !submitting) {
        selectedId='';selected=null;clearPath();put('mathStatus','No path loaded');$('mathStatus').className='status-tag';
        put('mathNotice','The selected job expired or was evicted. Import an exported path to check it again.');
      }
      controls();
    } catch(err) {if(e===epoch && serial===readSerial) reportError(err);}
    finally {if(e===epoch && serial===readSerial) {reader=null;schedule();}}
  }
  async function submit(body, replayId = null) {
    if (!writable()) { openLogin?.('Sign in with a managed account before starting a mathematical job.');return; }
    if(submitting) return;
    const e=epoch, intent=selectionSerial; submitting=true; controls();
    try {
      if (new TextEncoder().encode(JSON.stringify(body)).length>262144) throw new Error('The JSON request exceeds 256 KiB after encoding.');
      const endpoint=replayId?`/ecai/math/jobs/${encodeURIComponent(replayId)}/replay`:'/ecai/math/jobs';
      const job=payload(await request(endpoint,{method:'POST',body}));
      if(e!==epoch || disposed) return;
      jobs=[job,...jobs.filter(j=>j.id!==job.id)]; if(intent===selectionSerial)await selectJob(job.id);else renderJobs(); schedule();
    } catch(err) {if(e===epoch)reportError(err);}
    finally {if(e===epoch) {submitting=false;controls();}}
  }
  function discover(event) {
    event.preventDefault();
    try {
      const f=$('mathDiscoverForm').elements;
      const curve=(prefix)=>Object.fromEntries(['a2','a4','a6'].map(k=>[k,rationalInput(f.namedItem(`${prefix}_${k}`).value)]));
      const bounds=Object.fromEntries(['max_depth','max_curves','numerator_bound','denominator_bound'].map(k=>[k,Number(f.namedItem(k).value)]));
      if ($('mathMode').value==='explore') {
        bounds.timeout_ms=Number(f.namedItem('timeout_ms').value);
        void submit({operation:'explore',source:curve('source'),bounds});
      } else void submit({operation:'discover',source:curve('source'),target:curve('target'),bounds});
    } catch(err) {reportError(err);}
  }
  async function importFile() {
    const file=$('mathImportFile').files?.[0], e=epoch;
    if (!file || !writable()) return;
    try {
      if(file.size>196608) throw new Error('The import file exceeds 192 KiB.');
      const path_json=await file.text();
      if(e!==epoch || !writable()) return;
      // Preserve original bytes as text; do not round-trip exact fields through Number.
      await submit({operation:'import',path_json});
    } catch(err) {if(e===epoch)reportError(err);}
  }
  function download(kind) {
    const r=activeResult();
    if (!(selected?.preview || allowed()) || !r?.path_json) return;
    if (kind==='exploration' && !selected?.result?.exploration_json) return;
    const text=kind==='path'?r.path_json:kind==='exploration'?selected.result.exploration_json:pretty(selected.preview ? {schema:'ecai-math-sample-bundle/v1',live_verification:false,sample:currentSample()} : {schema:'ecai-math-dashboard-bundle/v1',selected_model_id:activeRowId || null,job:selected});
    const url=URL.createObjectURL(new Blob([text],{type:'application/json'})); downloads.add(url);
    const a=node('a');a.href=url;a.download=`ecai-math-${kind}-${selected.id}.json`;document.body.append(a);a.click();a.remove();
    setTimeout(()=>{URL.revokeObjectURL(url);downloads.delete(url);},10000);
  }
  function showTab(button,focus=false) {
    for(const tab of root.querySelectorAll('[data-math-tab]')) {
      const active=tab===button;tab.setAttribute('aria-selected',String(active));tab.tabIndex=active?0:-1;$(tab.dataset.mathTab).hidden=!active;
    }
    if(focus)button.focus();
  }

  function initialSample() {
    try {
      const id = new URLSearchParams(sampleSearch).get('math_sample');
      return MATH_SAMPLES.samples.some(s=>s.id===id) ? id : MATH_SAMPLES.default_id;
    } catch { return MATH_SAMPLES.default_id; }
  }
  function currentSample() { return MATH_SAMPLES.samples.find(s=>s.id===sampleId) || MATH_SAMPLES.samples[0]; }
  function fillEditor(sample) {
    const f=$('mathDiscoverForm').elements;
    for(const prefix of ['source','target']) for(const k of ['a2','a4','a6']) {
      const [n,d]=sample.path[prefix][k];f.namedItem(`${prefix}_${k}`).value=d==='1'?n:`${n}/${d}`;
    }
    for(const [k,v]of Object.entries(sample.bounds))f.namedItem(k).value=String(v);
    questionMode();
  }
  function renderCatalog() {
    const term=$('mathSampleFilter').value.trim().toLowerCase(), host=$('mathCatalog');host.replaceChildren();
    const filtered=MATH_SAMPLES.samples.filter(s=>`${s.title} ${s.category} ${s.summary} degree ${s.path.total_degree}`.toLowerCase().includes(term));
    for(const sample of filtered) {
      const b=node('button','math-sample-card');b.type='button';b.dataset.sampleId=sample.id;
      b.setAttribute('aria-pressed',String(sample.id===sampleId));
      b.append(node('small','',sample.category),node('strong','',sample.title),node('span','',`Degree ${sample.path.total_degree} · ${sample.path.hops} map${sample.path.hops===1?'':'s'} · ${sample.expected==='reject'?'must reject':'exact candidate'}`));host.append(b);
    }
    put('mathCatalogCount',`${filtered.length} of ${MATH_SAMPLES.samples.length} examples. Selection only loads local data; it never starts a job.`);
  }
  function loadSample(id) {
    const sample=MATH_SAMPLES.samples.find(s=>s.id===id);if(!sample)return;
    activeRowId='';clearPath();
    sampleId=id;selectionSerial++;readSerial++;reader?.abort();reader=null;stopPoll();selectedId='';
    const p=structuredClone(sample.path);
    // Display-only scaffold, explicitly NOT an imported or signed receipt.
    p.verification={status:'not_run_on_this_node',source_id:sample.model_ids[0],target_id:sample.model_ids.at(-1),formal_proof:false,
      steps:p.steps.map((step,i)=>({source_id:sample.model_ids[i],target_id:sample.model_ids[i+1],map_id:sample.map_ids[i],
        degree_checked:'Not run here',polynomial_identity:'Not run here',origin_preserved:'Not run here',checker:'Bundled candidate; use live replay'}))};
    selected={id:`sample-${id}`,preview:true,status:'preview',operation:'bundled_example',result:{path:p,path_json:sample.path_json}};
    selection={kind:'curve',index:0};$('mathSampleSelect').value=id;put('mathPathTitle','Supplied path · '+sample.title);
    put('mathSampleTitle',sample.title);put('mathSampleSummary',sample.summary);put('mathSampleQuestion',sample.question);
    $('mathSampleTags').replaceChildren(...[sample.category,`Degree ${p.total_degree}`,sample.expected==='reject'?'Expected rejection':'Exact coefficients'].map(t=>node('span','status-tag',t)));
    put('mathSampleMode',sample.can_discover?'Replay verifies these supplied maps. The endpoint editor can also ask the native degree-2 search to find a route afresh.':'Replay these explicit maps on the node. Degree-2-only endpoint search is not a substitute: it may return a different path, the identity, or no path within bounds.');
    put('mathStatus',sample.expected==='reject'?'Negative control · preview':'Example preview · not a live run');
    $('mathStatus').className='status-tag '+(sample.expected==='reject'?'math-status-failed':'math-status-preview');
    put('mathNotice','A public example is loaded locally. No account, payment, discovery job or live verification has been triggered.');
    fillEditor(sample);renderCatalog();renderSelected();
    $('mathPointInfinity').checked=false;$('mathPointX').required=true;$('mathPointY').required=true;put('mathScalarResult','');
    const presets=$('mathPointPresets');presets.replaceChildren();
    for(const [i,p]of sample.points.entries()) {const b=node('button','button button-outline button-sm',p.label);b.type='button';b.dataset.pointIndex=String(i);presets.append(b);}
    const first=sample.points[0];if(first){$('mathPointX').value=first.x;$('mathPointY').value=first.y;evaluatePoint();}schedule();
  }
  function renderPreviewEvidence() {
    const sample=currentSample(), check=sample.reference_check;
    $('mathChecks').replaceChildren(facts([
      ['Live node replay','Not run — this is a bundled public example'],
      ['Bundled independent algebra check',check.status==='algebraically_verified'?`Passed for ${check.maps} supplied maps (build-time Python check)`:'Rejected as expected (deliberately corrupted candidate)'],
      ['Bundled checker scope','Exact cleared-polynomial identity and degree bound; not source authentication or a formal proof certificate'],
      ['Native path identity','Bundled candidate ID — confirm with the native import/replay test'],
      ['DamageBDD report / signatures','Not attached; none inferred']
    ]),rawDetails('Bundled reference-check record (not a live run)',check));
    $('mathSearch').replaceChildren(node('p','context-hint','This is a supplied mathematical example, not a recorded discovery. No search counts, branches, execution times or payment amounts are invented.'),rawDetails('Suggested degree-2 discovery bounds',sample.bounds),node('p','context-hint',sample.question));
    $('mathRun').replaceChildren(facts([['Example',sample.id],['Fixture JSON SHA-256',sample.path_sha256],['Provenance','Bundled public library; not an authenticated DamageBDD execution'],['File',sample.file]]));
    for(const reference of sample.references) {
      try {const url=new URL(reference.url);if(url.protocol!=='https:')continue;const a=node('a','text-button',reference.title);a.href=url.href;a.target='_blank';a.rel='noopener noreferrer';$('mathRun').append(a,node('br'));}catch{/* Ignore malformed static reference URLs. */}
    }
  }
  function evaluatePoint(event) {
    event?.preventDefault();const path=activeResult()?.path;if(!path || !(selected?.preview || allowed()))return;
    const host=$('mathPointResult');host.replaceChildren();
    try {
      const trace=tracePoint(path,$('mathPointX').value,$('mathPointY').value,{infinity:$('mathPointInfinity').checked});
      for(const [i,p]of trace.entries()) {const box=node('div','math-point-image');box.append(node('small','',`E${i}`),node('strong','',p.infinity?'O · infinity':`(${p.x}, ${p.y})`));host.append(box);}
      host.className='math-point-result';
    } catch(error) {host.append(node('p','',message(error)));host.className='math-point-result math-point-error';}
    put('mathScalarResult','');
  }
  function multiplyPoint() {
    const path=activeResult()?.path;if(!path || !(selected?.preview || allowed()))return;
    try {
      if($('mathPointInfinity').checked){put('mathScalarResult','[n]O = O on the source curve.');return;}
      const n=Number($('mathPointScalar').value),p=scalarPoint(path.source,$('mathPointX').value,$('mathPointY').value,n);
      put('mathScalarResult',`[${n}]P = ${p.infinity?'O':`(${p.x}, ${p.y})`} on E0 (computed by the group law).`);
    } catch(error) {put('mathScalarResult',message(error));}
  }
  function exportSage() {
    const r=activeResult();
    if(!(selected?.preview||allowed()) || !r?.path_json)return;
    const url=URL.createObjectURL(new Blob([sageScript(JSON.parse(r.path_json))],{type:'text/x-python'}));downloads.add(url);
    const a=node('a');a.href=url;a.download='ecai-math-check.py';document.body.append(a);a.click();a.remove();
    setTimeout(()=>{URL.revokeObjectURL(url);downloads.delete(url);},10000);
  }
  for(const sample of MATH_SAMPLES.samples) {const option=node('option','',`${sample.title} · deg ${sample.path.total_degree}`);option.value=sample.id;$('mathSampleSelect').append(option);}
  on($('mathSampleSelect'),'change',()=>loadSample($('mathSampleSelect').value));
  on($('mathSampleFilter'),'input',renderCatalog);
  on($('mathCatalog'),'click',event=>{const b=event.target.closest('[data-sample-id]');if(b)loadSample(b.dataset.sampleId);});
  for(const [id,d]of [['mathSamplePrevious',-1],['mathSampleNext',1]])on($(id),'click',()=>{const i=MATH_SAMPLES.samples.findIndex(s=>s.id===sampleId);loadSample(MATH_SAMPLES.samples[(i+d+MATH_SAMPLES.samples.length)%MATH_SAMPLES.samples.length].id);});
  on($('mathSampleReset'),'click',()=>loadSample(sampleId));
  on($('mathSampleEdit'),'click',()=>{$('mathMode').value='discover';questionMode();fillEditor(currentSample());$('mathBuilderDisclosure').open=true;$('mathDiscoverForm').elements.namedItem('source_a2').focus();});
  on($('mathSampleVerify'),'click',()=>void submit({operation:'import',path_json:currentSample().path_json}));
  on($('mathSampleLink'),'click',async()=>{
    try {const url=new URL('/dashboard',globalThis.location.href);url.searchParams.set('math_sample',sampleId);url.hash='math';if(!navigator.clipboard?.writeText)throw new Error('Clipboard is unavailable.');await navigator.clipboard.writeText(url.href);toast?.('Public example link copied.');}catch(error){reportError(error);}
  });
  on($('mathPointForm'),'submit',evaluatePoint);on($('mathPointMultiply'),'click',multiplyPoint);
  on($('mathPointInfinity'),'change',()=>{const checked=$('mathPointInfinity').checked;$('mathPointX').required=!checked;$('mathPointY').required=!checked;evaluatePoint();});
  on($('mathPointPresets'),'click',event=>{const b=event.target.closest('[data-point-index]');if(!b)return;const p=currentSample().points[Number(b.dataset.pointIndex)];if(!p)return;$('mathPointX').value=p.x;$('mathPointY').value=p.y;$('mathPointInfinity').checked=false;evaluatePoint();});
  on($('mathSageExport'),'click',exportSage);

  on($('mathDiscoverForm'),'submit',discover);
  on($('mathDemo'),'click',()=>void submit({operation:'demo'}));
  on($('mathImportFile'),'change',controls);on($('mathImport'),'click',()=>void importFile());
  on($('mathReplay'),'click',()=>{if(selected?.status==='succeeded')void submit(selected.result?.exploration?{model_id:activeRowId}:{},selected.id);});
  on($('mathMode'),'change',questionMode);
  on($('mathNonIsoOnly'),'change',renderExploration);
  on($('mathExploreExport'),'click',()=>download('exploration'));
  on($('mathExploreResults'),'click',event=>{
    const b=event.target.closest('[data-model-id]');if(!b)return;
    activeRowId=b.dataset.modelId;selection={kind:'curve',index:0};
    $('mathPointResult').replaceChildren();put('mathScalarResult','');renderSelected();
  });
  on($('mathExport'),'click',()=>download('path'));on($('mathBundle'),'click',()=>download('bundle'));
  on($('mathRefresh'),'click',()=>void refresh());
  on($('mathGraph'),'click',event=>{const b=event.target.closest('button[data-kind]');if(!b)return;selection={kind:b.dataset.kind,index:Number(b.dataset.index)};highlightSelection();});
  on($('mathJobs'),'click',event=>{const b=event.target.closest('[data-job-id]');if(b)void selectJob(b.dataset.jobId);});
  for(const b of root.querySelectorAll('[data-math-tab]')) {
    on(b,'click',()=>showTab(b));
    on(b,'keydown',event=>{
      const tabs=[...root.querySelectorAll('[data-math-tab]')],i=tabs.indexOf(b);
      let next;if(event.key==='ArrowRight')next=(i+1)%tabs.length;else if(event.key==='ArrowLeft')next=(i+tabs.length-1)%tabs.length;else if(event.key==='Home')next=0;else if(event.key==='End')next=tabs.length-1;else return;
      event.preventDefault();showTab(tabs[next],true);
    });
  }
  on(document,'visibilitychange',()=>{if(document.hidden){stopPoll();reader?.abort();}else if(visible)void refresh();});
  questionMode(); reset();
  return {
    reset,refresh,
    setVisible(value){visible=Boolean(value);if(!visible){stopPoll();reader?.abort();}else schedule();},
    accessChanged(){controls();if(visible&&allowed())void refresh();},
    dispose(){reset();disposed=true;for(const [el,type,fn]of listeners)el.removeEventListener(type,fn);for(const url of downloads)URL.revokeObjectURL(url);downloads.clear();}
  };
}
