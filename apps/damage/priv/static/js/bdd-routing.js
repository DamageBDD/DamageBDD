// A route preference, never a browser-supplied endpoint or credential.
export function routeLabel(data) {
  const r = data?.route || {};
  return `${r.provider === 'any' ? 'Automatic BDD pool' : r.provider || 'Unavailable'} · ${r.model || 'connection default'}${Number.isInteger(data?.revision) ? ` · r${data.revision}` : ''}`;
}
export function mountBddRouting(root, {request, onChange = () => {}}) {
  if (!root) return {refresh:async()=>{}, reset(){}, dispose(){}};
  const $ = n => root.querySelector(`[data-route="${n}"]`), form = $('form');
  let snapshot = null, epoch = 0, busy = false, disposed = false;
  const life = new AbortController();let requests=new AbortController();
  const message = (s, bad=false) => { $('status').textContent=s; $('status').dataset.error=String(bad); };
  function controls() { $('fields').disabled = busy || snapshot?.can_manage !== true; $('refresh').disabled=busy; }
  async function refresh() {
    if (disposed || busy) return;
    const ticket=++epoch; busy=true; controls();
    try {
      const data=await request('/ai/bdd/routing',{signal:AbortSignal.any([requests.signal,AbortSignal.timeout(30000)])});
      if (ticket!==epoch || disposed) return;
      snapshot=data; $('summary').textContent=routeLabel(data);
      form.elements.provider.value=data.route.provider; form.elements.model.value=data.route.model || '';
      $('candidates').textContent=data.connections.length
        ? `BDD connections: ${data.connections.map(n=>`${n.id} (${n.provider} · ${n.default_model})`).join('; ')}.`
        : 'No enabled connection has the bdd role. An administrator must assign one before generating.';
      message(data.can_manage ? 'Node-wide preference. Keys, destinations and remote-role permissions remain in AI providers & roles.' : 'Read-only. Only an authorised node administrator can change the route.');
    } catch(e) { if(ticket===epoch && e.name!=='AbortError') { snapshot=null; $('summary').textContent='Unavailable'; message(e.message,true); } }
    finally { if(ticket===epoch){busy=false;controls();} }
  }
  form.addEventListener('submit',async e=>{
    e.preventDefault(); if(busy || !snapshot?.can_manage) return;
    const route={provider:form.elements.provider.value,model:form.elements.model.value.trim()};
    if(!window.confirm('Change the node-wide BDD authoring route? Remote-enabled BDD connections may receive prompts and code knowledge. This does not change a running agent’s planner.')) return;
    const ticket=epoch; busy=true;controls();
    try {
      await request('/ai/bdd/routing',{method:'POST',headers:{'x-damage-bdd':'1'},body:{revision:snapshot.revision,route},signal:AbortSignal.any([requests.signal,AbortSignal.timeout(30000)])});
      if(ticket!==epoch || disposed) return;
      busy=false; await refresh(); onChange();
      document.dispatchEvent(new CustomEvent('damage:bdd-routing-changed'));
    } catch(error) {if(ticket===epoch && error.name!=='AbortError') message(error.status===409 ? 'Settings changed elsewhere. Refresh before saving; your selection has not been applied.' : error.message,true);}
    finally {if(ticket===epoch){busy=false;controls();}}
  },{signal:life.signal});
  $('refresh').addEventListener('click',()=>void refresh(),{signal:life.signal});
  function reset(){epoch++;requests.abort();requests=new AbortController();busy=false;snapshot=null;$('summary').textContent='Not loaded';$('candidates').textContent='';form.reset();message('Sign in to inspect routing.');controls();}
  return {refresh,reset,dispose(){disposed=true;epoch++;life.abort();reset();}};
}
