import {TokenManager} from './wallet-switcher.js';
import {mountAgentWorkspace, workspaceRequest} from './agent-workspace.js';
function boot(){
  const root=document.querySelector('#agents-tab [data-agent-workspace]');if(!root)return;
  const workspace=mountAgentWorkspace(root,{
    request:workspaceRequest(()=>{const t=TokenManager.getToken();return t?{Authorization:`Bearer ${t}`}:{}}),
    canUse:()=>TokenManager.session()?.mode==='custodial'
  });
  document.addEventListener('damage:panelchange',e=>void workspace.setVisible(e.detail.id==='agents-tab'));
  // Every identity change clears private objectives, artifacts and in-flight replies.
  document.addEventListener('auth:changed',()=>{workspace.reset();void workspace.accessChanged();});
  window.addEventListener('pagehide',event=>{if(!event.persisted)workspace.dispose();else workspace.setVisible(false);});
  window.addEventListener('pageshow',event=>{if(event.persisted)void workspace.setVisible(!document.getElementById('agents-tab').hidden);});
  void workspace.setVisible(!document.getElementById('agents-tab').hidden);
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
