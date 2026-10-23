// A mountable panel: use authHeaders to supply the dashboard's existing bearer auth.
// The standalone page uses same-origin session cookies. Never persist a token here.
export const isTerminal = s => ['completed','failed','cancelled','cancelled_unreconciled','exhausted'].includes(s);
export const controlsFor = (s, task = {}) => {
  if (['budget_reserving','settling','receipting','reconciling'].includes(s)) return ['learning'];
  if (s === 'accounting_pending' || (s === 'interrupted' &&
      ['reservation_pending','settlement_pending','receipt_pending'].includes(task.budget?.status))) {
    return ['reconcile','learning'];
  }
  if (s === 'interrupted' && ['executing','verifying'].includes(task.interrupted_phase)) {
    return ['cancel','learning'];
  }
  if (isTerminal(s)) return ['learning'];
  if (s === 'awaiting_approval') return ['approve','reject','pause','cancel','learning'];
  if (s === 'paused') return ['resume','cancel','learning'];
  if (s === 'interrupted') return ['resume','cancel','learning'];
  return ['pause','cancel','learning'];
};
export function budgetLabel(task) {
  const b = task.budget;
  if (!b || b.mode === 'disabled') return 'Accounting disabled explicitly; no agent treasury claim.';
  return `${b.status}: ${b.spent_units} / ${b.max_cost_units} DAMAGE base units booked; ` +
    `${b.remaining_units} units remain under this task ceiling. AE transaction fees are separate.`;
}
export function mountAgentTasks(root, {authHeaders = () => ({}), intervalMs = 3000} = {}) {
  const $ = role => root.querySelector(`[data-role="${role}"]`);
  const form = $('create'), select = form.elements.template, goal = form.elements.goal;
  const controller = new AbortController();
  let selected = null, current = null, timer = null, disposed = false, busy = false, creation = null;
  const message = (text, error = false) => { $('message').textContent = text; $('message').classList.toggle('error', error); };
  async function api(path, options = {}) {
    const headers = {...await authHeaders(), ...(options.body ? {'content-type':'application/json','x-damage-agent':'1'} : {}), ...options.headers};
    const response = await fetch(`/api/agents${path}`, {...options, headers, credentials:'same-origin', signal:controller.signal, cache:'no-store'});
    const value = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(value.error || `Request failed (${response.status}); check your login and task permissions.`);
    return value;
  }
  function button(label, fn, disabled = false) {
    const b = document.createElement('button'); b.type = 'button'; b.textContent = label; b.disabled = disabled;
    b.addEventListener('click', fn, {signal:controller.signal}); return b;
  }
  async function choose(id) { selected = id; await details(); }
  async function details() {
    if (!selected) return;
    const id = selected;
    const [task, events] = await Promise.all([api(`/tasks/${encodeURIComponent(id)}`), api(`/tasks/${encodeURIComponent(id)}/events`)]);
    if (id !== selected || disposed) return;
    current = task; $('detail-section').hidden = false;
    $('budget').textContent = budgetLabel(task);
    $('detail').textContent = JSON.stringify(task,null,2);
    $('proposal').textContent = task.pending ? JSON.stringify(task.pending,null,2) : 'No pending proposal.';
    $('events').textContent = JSON.stringify(events.events,null,2);
    // Render actual report bytes as plain text; never execute model-authored HTML.
    const artifacts = new Map();
    for (const event of events.events) {
      const artifact = event.kind === 'action_succeeded' ? event.data?.result?.artifact : null;
      if (artifact && typeof artifact.name === 'string' && typeof artifact.content === 'string') {
        artifacts.set(artifact.name, artifact.content);
      }
    }
    $('artifacts').replaceChildren(...Array.from(artifacts, ([name, content]) => {
      const section = document.createElement('section');
      const title = document.createElement('h4'); title.textContent = name;
      const text = document.createElement('pre'); text.textContent = content;
      section.append(title, text); return section;
    }));
    if (!artifacts.size) $('artifacts').textContent = 'No generated artifact yet.';
    const actions = controlsFor(task.status, task);
    $('controls').replaceChildren(...actions.map(action => button(action === 'learning' ? 'Export candidate evidence' : action,
      () => mutate(action), busy)));
  }
  async function refresh() {
    const {tasks} = await api('/tasks');
    $('tasks').replaceChildren(...tasks.sort((a,b) => b.created_at-a.created_at).map(task => {
      const row = document.createElement('div'); row.className = 'task-row';
      const label = document.createElement('span');
      label.textContent = `${task.template} · ${task.status} · ${task.iteration} iterations · ${budgetLabel(task)}`;
      row.append(button(task.id.slice(0,12), () => choose(task.id).catch(e => message(e.message,true))), label);
      return row;
    }));
    if (!tasks.length) $('tasks').textContent = 'No tasks yet.';
    await details();
  }
  async function mutate(action) {
    if (busy || !current) return;
    busy = true;
    $('controls').querySelectorAll('button').forEach(b => { b.disabled = true; });
    try {
      const id = current.id;
      if (action === 'learning') {
        const data = await api(`/tasks/${encodeURIComponent(id)}/learning`);
        const url = URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));
        const a = document.createElement('a'); a.href = url; a.download = `agent-${id}-candidate.json`; a.click();
        setTimeout(() => URL.revokeObjectURL(url),1000);
      } else {
        const hash = current.pending?.hash;
        if (action === 'approve' && !window.confirm('Approve this exact displayed proposal? External effects may not be reversible.')) return;
        await api(`/tasks/${encodeURIComponent(id)}/command`, {method:'POST',body:JSON.stringify({command:action,proposal_hash:hash || ''})});
        message(`Task command accepted: ${action}.`);
      }
    } catch (e) { if (e.name !== 'AbortError') message(e.message,true); }
    finally { busy = false; if (!disposed) await refresh().catch(e => message(e.message,true)); }
  }
  form.addEventListener('submit', async e => {
    e.preventDefault(); if (busy) return;
    busy = true; form.querySelector('button').disabled = true;
    const payload = JSON.stringify({template:select.value,goal:goal.value});
    // Retain the key on uncertain transport failure; a retry cannot create a duplicate.
    if (!creation || creation.payload !== payload) creation = {payload,key:crypto.randomUUID()};
    try {
      const task = await api('/tasks',{method:'POST',headers:{'idempotency-key':creation.key},body:payload});
      creation = null; selected = task.id; message(`Task accepted: ${task.id}.`);
    } catch (err) { if (err.name !== 'AbortError') message(err.message,true); }
    finally { busy = false; form.querySelector('button').disabled = false; await refresh().catch(err => message(err.message,true)); }
  },{signal:controller.signal});
  async function loop() {
    if (disposed) return;
    try { if (!document.hidden && !busy) await refresh(); }
    catch (e) { if (e.name !== 'AbortError') message(e.message,true); }
    finally { if (!disposed) timer = setTimeout(loop,intervalMs); }
  }
  (async () => {
    try {
      const {templates} = await api('/templates');
      select.replaceChildren(...templates.map(t => { const o = document.createElement('option'); o.value = t.id; o.textContent = `${t.id} — ${t.description}${t.accounting?.mode === "aeternity" ? ` (ceiling ${t.accounting.max_cost_units} base units)` : ""}`; return o; }));
      form.querySelector('button').disabled = templates.length === 0;
      message(templates.length ? 'Only operator-approved capabilities are available.' : 'No authorised templates are configured.');
      await loop();
    } catch (e) { if (e.name !== 'AbortError') message(e.message,true); }
  })();
  return () => { disposed = true; clearTimeout(timer); controller.abort(); };
}
