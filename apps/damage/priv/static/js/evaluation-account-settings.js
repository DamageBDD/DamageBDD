/* Damage account settings use the exact ECAI account policy API, not a second store. */
export function initEvaluationAccountSettings({api, getToken, session}) {
  const $=id=>document.getElementById(id),host=$('account-evaluation-fields'),form=$('account-evaluation-form');
  if(!host||!form)return {refresh:async()=>{},reset(){}};
  let revision=null,epoch=0,controller=null;const inputs=new Map();
  function notice(text){$('account-evaluation-status').textContent=text;}
  function reset(){epoch++;controller?.abort();controller=null;revision=null;inputs.clear();host.replaceChildren();form.reset();$('account-evaluation-save').disabled=true;notice('Managed email sign-in is required.');}
  async function refresh(){
    if(session()?.mode!=='custodial'||!getToken()){reset();return;}
    const own=++epoch,token=getToken();controller?.abort();controller=new AbortController();
    try {
      const response=await api('/ecai/eval/settings',{signal:controller.signal});
      if(own!==epoch||token!==getToken())return;
      const data=response.data;if(response.ok!==true||!data)throw new Error('Evaluation settings unavailable');
      revision=data.version;inputs.clear();host.replaceChildren();
      for(const [name,value] of Object.entries(data.preferences)){
        const label=document.createElement('label');label.textContent=name.replaceAll('_',' ');let input;
        if(name==='target_ids'||name==='knowledge_mode'){
          input=document.createElement('select');input.multiple=name==='target_ids';
          const opts=name==='target_ids'?data.targets.map(t=>[t.id,`${t.id} · ${t.model}`]):[['none','No reference context'],['ecai','ECAI reference retrieval']];
          for(const [id,text] of opts){const op=document.createElement('option');op.value=id;op.textContent=text;op.selected=Array.isArray(value)?value.includes(id):value===id;input.append(op);}
        }else{
          input=document.createElement('input');input.type=typeof value==='boolean'?'checkbox':'number';
          if(input.type==='checkbox')input.checked=value;else{input.value=String(value);input.step='1';input.required=true;}
        }
        input.name=name;label.append(input);host.append(label);inputs.set(name,input);
      }
      $('account-evaluation-save').disabled=false;
      notice(`${data.node_policy.enabled?'Node enabled':'Node disabled'} · ${data.daily_reserved_calls}/${data.effective.daily_calls} reserved calls today. Node limits take precedence. Remote consent sends selected prompts/reference text to approved providers.`);
    }catch(error){if(own!==epoch||error.name==='AbortError')return;revision=null;$('account-evaluation-save').disabled=true;notice(error.status===404||error.status===503?'The ECAI evaluation service is not running on this node.':error.message);}
  }
  form.addEventListener('submit',event=>{
    event.preventDefault();void(async()=>{
      if(revision===null||session()?.mode!=='custodial')return;
      const own=epoch,token=getToken(),changes={};$('account-evaluation-save').disabled=true;
      try{
        for(const [name,input] of inputs){
          if(input.multiple)changes[name]=[...input.selectedOptions].map(x=>x.value);
          else if(input.type==='checkbox')changes[name]=input.checked;
          else if(input.type==='number'){const n=Number(input.value);if(!Number.isSafeInteger(n))throw new Error(`Invalid integer: ${name}`);changes[name]=n;}
          else changes[name]=input.value;
        }
        await api('/ecai/eval/settings',{method:'POST',body:JSON.stringify({version:revision,changes})});
        if(own!==epoch||token!==getToken())return;
        await refresh();notice('Evaluation preferences saved for this account.');
      }catch(error){if(own===epoch&&token===getToken())notice(error.status===409?'Settings changed elsewhere. Refresh before saving again.':error.message);}
      finally{if(own===epoch&&revision!==null)$('account-evaluation-save').disabled=false;}
    })();
  });
  document.addEventListener('auth:changed',reset);window.addEventListener('pagehide',reset);
  return {refresh,reset};
}
