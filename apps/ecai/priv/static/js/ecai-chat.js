  // ========= Optional external crypto.js =========
  // If present, should set window.ECAICrypto = { encrypt(plainBytes, passphrase|key), decrypt(cipherBytes, passphrase|key, {iv,salt}) }
  // We'll also attempt <script src="/crypto.js"></script> via dynamic injection below.
/********************
 * Helpers & State  *
 ********************/
const enc = new TextEncoder();
const dec = new TextDecoder();
const nowISO = () => new Date().toISOString();
const uid = () => Math.random().toString(36).slice(2) + Date.now().toString(36);

const State = {
  projects: [],
  activeProjectId: 'default',
  keyring: {}, // { [projectId]: { passphrase } }
  conversations: [], // decrypted, in-memory
  activeConvId: null,
  sessionId: uid(),
};

/********************
 * Local persistence *
 ********************/
const Local = {
  read(k, fallback){ try{ return JSON.parse(localStorage.getItem(k) || JSON.stringify(fallback)); }catch{ return fallback; } },
  write(k,v){ localStorage.setItem(k, JSON.stringify(v)); },
};

const Vault = {
  key: 'ecai_vault_v1',
  all(){ return Local.read(this.key, {}); },
  save(obj){ const all=this.all(); all[obj.id]=obj; Local.write(this.key, all); },
  drop(id){ const all=this.all(); delete all[id]; Local.write(this.key, all); },
  list(projectId){ return Object.values(this.all()).filter(x=>x.project_id===projectId); }
};

/********************
 * Server API (opt)  *
 ********************/
const Server = {
  async chat({ sessionId, message }){
    const r = await fetch('/v1/chat/completions',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({session_id:sessionId,message})});
    if(!r.ok) throw new Error('Chat failed: '+r.status); return r.json();
  },
  async listHistory(projectId){ try{ const r=await fetch('/api/history?project_id='+encodeURIComponent(projectId)); if(!r.ok) throw 0; return r.json(); }catch{ return null; } },
  async saveHistory(payload){ try{ const r=await fetch('/api/history/save',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload)}); if(!r.ok) throw 0; return r.json(); }catch{ return null; } }
};

/********************
 * Crypto Adapter    *
 ********************/
const Crypto = (function(){
  let ready=false, api=null;
  async function ensure(){
    if(ready) return api;
    if(window.ECAICrypto){ api=window.ECAICrypto; ready=true; return api; }
    try{ // try dynamic script include
      await new Promise((res,rej)=>{ const s=document.createElement('script'); s.src='/crypto.js'; s.async=true; s.onload=res; s.onerror=rej; document.head.appendChild(s); });
      if(window.ECAICrypto){ api=window.ECAICrypto; ready=true; return api; }
    }catch{}
    // Fallback WebCrypto
    api={
      async kdf(pass,salt){ const base=await crypto.subtle.importKey('raw', enc.encode(pass), {name:'PBKDF2'}, false, ['deriveKey']); return crypto.subtle.deriveKey({name:'PBKDF2', hash:'SHA-256', salt, iterations:150000}, base, {name:'AES-GCM', length:256}, false, ['encrypt','decrypt']); },
      async encrypt(plainBytes, pass){ const salt=crypto.getRandomValues(new Uint8Array(16)); const iv=crypto.getRandomValues(new Uint8Array(12)); const key=await this.kdf(pass, salt); const ct=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM', iv}, key, plainBytes)); return {ciphertext:ct, iv, salt}; },
      async decrypt(cipherBytes, pass, {iv,salt}){ const key=await this.kdf(pass, salt); const pt=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM', iv}, key, cipherBytes)); return pt; }
    };
    ready=true; return api;
  }
  return { ensure };
})();

/********************
 * Base64 helpers    *
 ********************/
function b64e(bytes){ let s=''; for(let i=0;i<bytes.length;i++) s+=String.fromCharCode(bytes[i]); return btoa(s); }
function b64d(b64){ const s=atob(b64); const out=new Uint8Array(s.length); for(let i=0;i<s.length;i++) out[i]=s.charCodeAt(i); return out; }

/********************
 * Minimal Markdown  *
 ********************/
function md(html){
  html=html.replace(/^###\s(.+)$/gim,'<h3>$1</h3>');
  html=html.replace(/^##\s(.+)$/gim,'<h2>$1</h2>');
  html=html.replace(/^#\s(.+)$/gim,'<h1>$1</h1>');
  html=html.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');
  html=html.replace(/`([^`]+)`/g,'<code>$1</code>');
  html=html.replace(/^\-\s(.+)$/gim,'<li>$1</li>');
  html=html.replace(/(<li>.*<\/li>)/gms,'<ul>$1</ul>');
  html=html.replace(/\n\n/g,'<br/><br/>');
  return html;
}

/********************
 * UI rendering      *
 ********************/
const el = id=>document.getElementById(id);

function renderProjects(){
  const sel = el('projectSelect'); sel.innerHTML='';
  State.projects.forEach(p=>{ const o=document.createElement('option'); o.value=p.id; o.textContent=p.name; sel.appendChild(o); });
  sel.value=State.activeProjectId;
  const p = State.projects.find(x=>x.id===State.activeProjectId);
  el('projectName').textContent = 'Project: ' + (p?p.name:'—');
}

function renderConversations(){
  const list = el('convList'); list.innerHTML='';
  if(State.conversations.length===0){ const d=document.createElement('div'); d.style.color='var(--muted)'; d.style.fontSize='12px'; d.style.padding='8px'; d.textContent='No chats yet.'; list.appendChild(d); }
  State.conversations.forEach(c=>{
    const div=document.createElement('div'); div.className='item'+(State.activeConvId===c.id?' active':'');
    const title=document.createElement('div'); title.textContent=c.title||'Untitled';
    const small=document.createElement('small'); small.textContent=new Date(c.updated_at||c.created_at).toLocaleString();
    const del=document.createElement('div'); del.innerHTML='<button class="link danger">Delete</button>';
    del.onclick=(e)=>{ e.stopPropagation(); deleteChat(c.id); };
    div.appendChild(title); div.appendChild(small); div.appendChild(del);
    div.onclick=()=>{ State.activeConvId=c.id; renderConversations(); renderMessages(); };
    list.appendChild(div);
  });
}

function renderMessages(){
  const wrap = el('messages'); wrap.innerHTML='';
  const conv = State.conversations.find(c=>c.id===State.activeConvId);
  if(!conv){ const d=document.createElement('div'); d.style.color='var(--muted)'; d.textContent='Start a conversation…'; wrap.appendChild(d); return; }
  conv.messages.forEach(m=>{
    const b=document.createElement('div'); b.className='bubble '+(m.role==='user'?'user':'asst');
    const box=document.createElement('div');
    if(m.md){ box.className='md'; box.innerHTML=md(m.content); } else { box.textContent=m.content; }
    b.appendChild(box);
    const t=document.createElement('div'); t.className='timestamp'; t.textContent=new Date(m.ts).toLocaleString();
    const outer=document.createElement('div'); outer.appendChild(b); outer.appendChild(t);
    outer.style.margin = '8px 0';
    wrap.appendChild(outer);
    // Optional: sources preview
    if(m.meta && m.meta.results){
      const s=document.createElement('div'); s.className='sources';
      s.textContent='Sources: '+ m.meta.results.map(r=> (r.record?.name||r.record?.category||'Untitled') + ' ['+r.doc_id+']').join(' • ');
      wrap.appendChild(s);
    }
  });
  wrap.scrollTop = wrap.scrollHeight;
}

/********************
 * Actions           *
 ********************/
function ensureDefaultProject(){
  if(!State.projects.find(p=>p.id==='default')){
    State.projects.push({id:'default', name:'Default Project', created_at:nowISO()});
  }
}

function setPassphrase(){
  const pass = prompt('Set/Update project passphrase (kept locally only):');
  if(pass==null) return; State.keyring[State.activeProjectId] = { passphrase: pass };
  persistMeta(); alert('Passphrase saved locally.');
}

function newProject(){ const name=prompt('Project name?'); if(!name) return; const p={id:uid(), name, created_at:nowISO()}; State.projects.push(p); State.activeProjectId=p.id; persistMeta(); loadProject(); }
function renameProject(){ const p=State.projects.find(x=>x.id===State.activeProjectId); if(!p) return; const name=prompt('New name?', p.name); if(!name) return; p.name=name; persistMeta(); renderProjects(); }
function deleteProject(){ if(State.activeProjectId==='default'){ alert('Cannot delete default project.'); return; } if(!confirm('Delete project and local history (server copies unaffected)?')) return; const pid=State.activeProjectId; State.projects=State.projects.filter(x=>x.id!==pid); Object.keys(Vault.all()).forEach(id=>{ const item=Vault.all()[id]; if(item.project_id===pid) Vault.drop(id); }); State.activeProjectId='default'; persistMeta(); loadProject(); }

function newChat(){ const c={id:uid(), project_id:State.activeProjectId, title:'New chat', messages:[], created_at:nowISO(), updated_at:nowISO()}; State.conversations=[c,...State.conversations]; State.activeConvId=c.id; renderConversations(); renderMessages(); }
function deleteChat(id){ if(!confirm('Delete this chat from local vault (server copy unaffected)?')) return; State.conversations=State.conversations.filter(c=>c.id!==id); Vault.drop(id); if(State.activeConvId===id) State.activeConvId=State.conversations[0]?.id||null; renderConversations(); renderMessages(); }

async function send(){
  const ta=el('input'); const text=ta.value.trim(); if(!text) return; ta.value=''; setStatus('Thinking deterministically…');
  let conv = State.conversations.find(c=>c.id===State.activeConvId);
  if(!conv){ newChat(); conv = State.conversations.find(c=>c.id===State.activeConvId); }
  const userMsg={role:'user', content:text, ts:nowISO()};
  conv.messages.push(userMsg); conv.updated_at=nowISO();
  renderMessages();
  try{
    const res = await Server.chat({ sessionId: State.sessionId, message: text });
    const reply = res.reply_md || res.reply || '(no reply)';
    const asst={role:'assistant', content:reply, md:true, ts:nowISO(), meta:{results:res.results, proofs:res.proofs}};
    conv.messages.push(asst); conv.updated_at=nowISO();
    if(conv.title==='New chat'){ const plain=reply.replace(/[#*`>/\-]/g,' ').trim(); conv.title=(plain.split(/\n|\.|!|\?/)[0]||'New chat').slice(0,60); }
    renderConversations(); renderMessages();
    await persistConversation(conv);
    setStatus('');
  }catch(e){ setStatus('Error: '+e.message); }
}

function setStatus(t){ el('status').textContent=t; }

/********************
 * Persistence       *
 ********************/
function persistMeta(){ Local.write('ecai_projects_v1', State.projects); Local.write('ecai_active_project', State.activeProjectId); Local.write('ecai_keyring_v1', State.keyring); }

async function persistConversation(conv){
  const api = await Crypto.ensure();
  const pass = (State.keyring[State.activeProjectId]||{}).passphrase || '';
  const plain = enc.encode(JSON.stringify(conv));
  const { ciphertext, iv, salt } = await api.encrypt(plain, pass);
  const payload = { project_id: conv.project_id, id: conv.id, ciphertext: b64e(ciphertext), iv: b64e(iv), salt: b64e(salt), meta:{ title: conv.title, updated_at: conv.updated_at } };
  const saved = await Server.saveHistory(payload); if(!saved) Vault.save(payload);
}

async function loadProject(){
  renderProjects();
  el('sessionInfo').textContent='Session: '+State.sessionId.slice(0,6)+'…';
  const api = await Crypto.ensure();
  const pass = (State.keyring[State.activeProjectId]||{}).passphrase || '';
  // load server list then fallback
  const serverList = await Server.listHistory(State.activeProjectId);
  const list = serverList ?? Vault.list(State.activeProjectId);
  const decrypted=[];
  for(const item of (list||[])){
    try{
      const pt = await api.decrypt(b64d(item.ciphertext), pass, { iv: b64d(item.iv), salt: b64d(item.salt) });
      const conv = JSON.parse(dec.decode(pt)); decrypted.push(conv);
    }catch(e){ console.warn('Decrypt failed', item?.id, e); }
  }
  decrypted.sort((a,b)=>(b.updated_at||'').localeCompare(a.updated_at||''));
  State.conversations=decrypted; State.activeConvId=decrypted[0]?.id||null;
  renderConversations(); renderMessages();
}

/********************
 * Bootstrap         *
 ********************/
(function init(){
  State.projects = Local.read('ecai_projects_v1', []);
  State.activeProjectId = Local.read('ecai_active_project', 'default');
  State.keyring = Local.read('ecai_keyring_v1', {});
  ensureDefaultProject(); persistMeta();

  el('projectSelect').addEventListener('change', (e)=>{ State.activeProjectId=e.target.value; persistMeta(); loadProject(); });
  el('btnNewProject').addEventListener('click', newProject);
  el('btnRenameProject').addEventListener('click', renameProject);
  el('btnDeleteProject').addEventListener('click', deleteProject);
  el('btnPassphrase').addEventListener('click', setPassphrase);
  el('btnNewChat').addEventListener('click', newChat);
  el('btnSend').addEventListener('click', send);
  el('input').addEventListener('keydown', e=>{ if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); send(); } });

  loadProject();
})();
