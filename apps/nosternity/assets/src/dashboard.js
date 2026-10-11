import { escapeHTML as esc, validPubkey } from './core.js';
import { Wallet, connectBunker, verifyEvent, deadline } from './connections.js';
import { npubEncode, decode } from 'nostr-tools/nip19';
const $ = s => document.querySelector(s);
// Server-rendered attributes are escaped by Mustache; use textContent or esc()
// when displaying these operator values after client-side navigation.
const brand = {name:document.body.dataset.nodeName || 'Nosternity',
 title:document.body.dataset.nodeTitle || document.title,
 description:document.body.dataset.nodeDescription || ''};
const state = { page:'explore', scope:'global', query:'', kind:'all', session:null, damage:null,
  signer:null, signerType:'', wallet:null, balance:null, events:[], account:null, epoch:0 };
let dialogEpoch=0, pollTimer, toastTimer, pendingProof=null, authBusy=false;
// Keep cookie-setting requests serialized with account switches and dialog closure.
async function authenticating(fn){if(authBusy)throw Error('Wait for the current sign-in to finish.');authBusy=true;try{return await fn();}finally{authBusy=false;}}
const labels={explore:'Explore',account:'My feed',saved:'Saved notes',analytics:'Search & index',wallet:'Lightning wallet',signer:'Key & signing',settings:'Connections'};
const messages={account_not_found:'No account exists for this identity yet. Choose Create account and prove your identity again.',
 invalid_proof:'The signature could not be verified. Start a new sign-in.',invalid_challenge:'This challenge expired or was already used. Start again.',
 nostr_login_required:'Sign in with Nostr to use this action.',damage_login_required:'Sign in to a managed DamageBDD account for this action.',
 origin_rejected:'Open the configured node origin. Ask your operator to check browser_auth_origin.',
 auth_unavailable:'Authentication is unavailable. Check the server configuration or try again.',
 unauthorized:'Your session has expired. Sign in again.',rate_limited:'Too many requests. Wait a minute and retry.',signup_unavailable:'New accounts are currently unavailable.'};
async function api(path,body,extra={}) {
 const response=await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',
  headers:{Accept:'application/json','X-Nosternity-Auth':'1','X-Damage-Auth':'1',...(body===undefined?{}:{'Content-Type':'application/json'}),...extra},
  body:body===undefined?undefined:typeof body==='string'?body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
 let data;try{data=await response.json();}catch{throw Error('The server did not return JSON. Check the dashboard deployment.');}
 if(!response.ok){const e=Error(messages[data.error]||data.message||String(data.error||'Request failed'));e.code=response.status;throw e;}return data;
}
function toast(message){$('#toast').textContent=message;$('#toast').style.display='block';clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').style.display='none',7000);}
function fail(error){const text=error?.message||'This request could not be completed.';if($('#modal').open)$('#modalError').textContent=text;else toast(text);}
function close(){if(authBusy)return;dialogEpoch++;clearTimeout(pollTimer);if(pendingProof?.provider!==state.signer)pendingProof?.provider.close?.();pendingProof=null;$('#modal').close();$('#modalBody').replaceChildren();}
function modal(html){close();$('#modalBody').innerHTML=html;$('#modalError').textContent='';$('#modal').showModal();return dialogEpoch;}
function short(key){return key?key.slice(0,8)+'…'+key.slice(-6):'Not connected';}
function intent(){return $('#authIntent')?.value||'login';}
function publicKey(input){const s=input.trim();if(validPubkey(s))return s;if(s.startsWith('npub1')){const n=decode(s);if(n.type==='npub')return n.data;}throw Error('Enter a full Nostr public key or npub.');}
function prefs(){return state.account?.preferences||{spam:true,duplicates:true,muted:[],words:[],bookmarks:[]};}
async function restore(){
 const epoch=state.epoch;
 const results=await Promise.allSettled([api('/api/nosternity/auth/session'),api('/accounts/session')]);
 if(epoch!==state.epoch)return;
 for(let i=0;i<results.length;i++){const r=results[i];const key=i===0?'session':'damage';
  if(r.status==='fulfilled')state[key]=r.value;else if(r.reason.code===401)state[key]=null;else throw r.reason;}
 const account=state.session?await api('/api/nosternity/account'):null;if(epoch!==state.epoch)return;state.account=account;
 chrome();
}
function chrome(){const s=state.session;$('.headeractions button').innerHTML=s?'Your account ↗':'Connect account ↗';
 $('#mode').textContent=s?'● '+(s.provider==='nostr'?'Nostr connected':s.provider==='lightning'?'Lightning identity':'DamageBDD identity'):'○ Guest';
 $('#savedCount').textContent=prefs().bookmarks.length;
 const p=$('.profile');p.innerHTML='<span class="avatar">'+(s?'◎':'↗')+'</span><span>'+esc(s?short(s.subject):'Make yourself at home')+'<small>'+esc(s?s.provider+' identity':'Connect your account')+'</small></span>';
}
async function fragment(name){const r=await fetch('/dashboard/fragments/'+name,{credentials:'same-origin'});if(!r.ok)throw Error('Dashboard fragment is unavailable. Deploy templates and assets together.');return r.text();}
async function navigate(page){if(!labels[page])return;const epoch=++state.epoch;state.page=page;location.hash=page;
 $('#crumb').textContent=labels[page];document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active',b.dataset.page===page));
 const titles={explore:['',brand.description],
 account:['Your voice.<br>Your <em>community.</em>','Your public notes and the people you choose to follow.'],saved:['Good ideas.<br>Worth <em>keeping.</em>','Bookmarks saved to your '+brand.name+' account.'],
 analytics:['A clearer view.<br>Of your <em>network.</em>','Real index counts and dashboard activity since this node started.'],wallet:['Small payments.<br>Real <em>possibilities.</em>','A wallet connection is separate from your login.'],
 signer:['Your keys.<br>Your <em>say.</em>','Sign with your browser extension or remote nsecBunker.'],settings:['Your connections.<br>Your <em>choice.</em>','Your accounts and permissions, clearly separated.']};
 if(page==='explore')$('#title').textContent=brand.title;else $('#title').innerHTML=titles[page][0];
 $('#subtitle').textContent=titles[page][1];
 if(['explore','account','saved'].includes(page)){state.scope=page==='account'?'account':page==='saved'?'saved':state.scope==='saved'?'global':state.scope;
  const html=await fragment('feed');if(epoch!==state.epoch)return;$('#content').innerHTML=html;$('#search').value=state.query;$('#kind').value=state.kind;await loadFeed(epoch);}
 else if(page==='settings'){settings();}
 else {const html=await fragment(page);if(epoch!==state.epoch)return;$('#content').innerHTML=html;if(page==='analytics')await metrics(epoch);if(page==='wallet')walletView();if(page==='signer')signerView();}
 chrome();
}
function blank(title,text){return '<div class="empty"><span>✳</span><h2>'+esc(title)+'</h2><p>'+esc(text)+'</p></div>';}
function post(e){const name=short(e.pubkey);const date=new Date(e.created_at*1000);const dateText=Number.isFinite(date.getTime())?date.toLocaleString():'Unknown time';
 return '<article class="post"><div class="posthead"><span class="avatar">'+esc(e.pubkey.slice(0,2).toUpperCase())+'</span><div><b>'+esc(name)+'</b><small>Signed Nostr event</small></div><time>'+esc(dateText)+'</time></div><p>'+esc(e.content)+'</p><div class="tags">'+(e.tags||[]).filter(t=>t[0]==='t').slice(0,5).map(t=>'#'+esc(t[1])).join(' &nbsp; ')+'</div><div class="postactions"><button data-action="details" data-id="'+e.id+'">↗ View event</button><button data-action="mute" data-id="'+e.id+'">⊘ Mute</button><button data-action="bookmark" data-id="'+e.id+'">'+(prefs().bookmarks.includes(e.id)?'▣ Saved':'▱ Save')+'</button></div></article>';
}
async function loadFeed(epoch=state.epoch){
 $('#posts').innerHTML=blank('Finding your next discovery…','Loading notes from this relay.');
 try{const r=await api('/api/nosternity/feed',{scope:state.scope,query:state.query,kind:state.kind==='all'?'all':Number(state.kind),limit:50});if(epoch!==state.epoch)return;
  state.events=r.results.map(r=>r.event).filter(e=>{try{return verifyEvent(e);}catch{return false;}});
  $('#posts').innerHTML=state.events.length?state.events.map(post).join(''):blank('Nothing here yet',state.scope==='following'?'The relay needs your contact list and notes from the people you follow.':'Try another search, refresh, or publish your first note.');
  $('#filterSummary').textContent=(prefs().spam?'Spam filtering on':'Spam filtering off')+' · '+r.hidden+' hidden from the candidate batch';
  $('#feedSummary').textContent=state.events.length+' shown · Up to 50 candidate events';
  document.querySelectorAll('[data-scope]').forEach(b=>b.classList.toggle('active',b.dataset.scope===state.scope));
  const m=await api('/api/nosternity/analytics');if(epoch!==state.epoch)return;
  $('#snapshot').innerHTML='<div>Stored events <b>'+esc(m.relay.events)+'</b></div><div>Text index <b>'+esc(m.relay.index)+'</b></div><div>Capacity <b>'+esc(m.relay.max_events)+'</b></div>';
 }catch(e){if(epoch===state.epoch){$('#posts').innerHTML=blank('We couldn’t load this feed',e.message);$('#filterSummary').textContent='Feed unavailable';}}
}
async function metrics(epoch){const m=await api('/api/nosternity/analytics');if(epoch!==state.epoch)return;const a=m.relay,d=m.dashboard;
 $('#metrics').innerHTML=[['Stored events',a.events],['Indexed records',a.index],['Active subscriptions',a.subscriptions],['Dashboard searches',d.searches],['Filtered candidates',d.hidden],['Capacity',a.max_events]].map(([name,value])=>'<div class="card"><span class="caption">'+esc(name)+'</span><strong class="big">'+esc(value)+'</strong></div>').join('')+
 '<div class="card wide"><h2>Relay state</h2><p>Archive hydration '+(a.hydrated?'complete or disabled':'in progress')+'. Dashboard metrics cover requests on this node since '+esc(new Date(d.since*1000).toLocaleString())+'. They reset when the authentication worker restarts.</p><p>Mean dashboard feed/search time: '+(d.requests?Math.round(d.duration_ms/d.requests):0)+' ms. Counts are not whole-network totals.</p><button data-action="refresh">Refresh ↻</button></div>';
}
function walletView(){if(!$('#walletStatus'))return;$('#walletStatus').textContent=state.wallet?'NWC connected':'Not connected';$('#walletBalance').textContent=state.balance===null?'—':state.balance.toLocaleString();$('#damageStatus').textContent=state.damage?'Signed in as '+short(state.damage.address)+' ('+state.damage.mode+').':'No DamageBDD session connected.';}
function signerView(){if($('#identity'))$('#identity').textContent=state.session?.provider==='nostr'?npubEncode(state.session.subject)+(state.signer?' · '+state.signerType:' · reconnect your signer to publish'):'No Nostr session. Connect your signer to sign in or create an account.';}
function settings(){const s=state.session;$('#content').innerHTML='<div class="split"><div class="card"><h2>Your '+esc(brand.name)+' account</h2><p>'+esc(s?s.provider+' · '+short(s.subject):'Exploring as a guest')+'</p><p>One proved identity per account. Signing in with another provider switches accounts; no identity is silently linked.</p><button class="dark" data-action="login">Sign in / create account</button><button data-action="filters">Feed preferences</button><button data-action="signout">Sign out</button></div><div class="card"><h2>Connected services</h2><p>This dashboard uses the node listener at '+esc(location.origin)+'. DamageBDD authentication and NWC routes are mounted on this origin.</p><button data-action="damageLogin">Connect DamageBDD</button><button data-action="nwc">Connect Lightning wallet</button><p>No private keys, bearer tokens, or wallet connection secrets are stored in localStorage.</p></div></div>';}
function authDialog(){modal($('#authTemplate').innerHTML);}
async function prepareNostr(provider,type,wantedIntent){
 const startingEpoch=dialogEpoch;const expected=await deadline(provider.getPublicKey());if(startingEpoch!==dialogEpoch){await provider.close?.();return;}if(!validPubkey(expected))throw Error('Signer returned an invalid public key.');
 const challenge=await api('/api/nosternity/auth/nostr/challenge',{intent:wantedIntent});if(startingEpoch!==dialogEpoch){await provider.close?.();return;}
 const epoch=modal('<h2>Review your '+(wantedIntent==='signup'?'account creation':'sign-in')+'</h2><p>You are proving ownership of this Nostr identity at <b>'+esc(location.origin)+'</b>.</p><p class="mono">'+esc(npubEncode(expected))+'</p><p>This one-use HTTP authentication signature does not publish a note or authorize a payment.</p><button class="dark" data-action="signProof">Approve & sign challenge</button>');
 pendingProof={provider,type,expected,challenge,epoch};
}
async function signProof(){const p=pendingProof;if(!p)throw Error('Start a new sign-in.');const event=await deadline(p.provider.signEvent({...p.challenge.event,created_at:Math.floor(Date.now()/1000)}));
 if(p.epoch!==dialogEpoch)return;if(!verifyEvent(event)||event.pubkey!==p.expected)throw Error('Signer identity changed. Start again.');
 const s=await authenticating(()=>api('/api/nosternity/auth/nostr/verify',p.challenge.payload,{Authorization:'Nostr '+btoa(JSON.stringify(event))}));
  const previous=state.signer;state.signer=p.provider;state.signerType=p.type;state.session=s;pendingProof=null;if(previous!==state.signer)await previous?.close?.();close();await restore();await navigate('account');toast('Nostr account connected.');
}
async function nostrLogin(){const wanted=intent();if(!window.nostr?.getPublicKey)throw Error('Install or unlock a NIP-07 browser signer, or choose nsecBunker.');await prepareNostr(window.nostr,'Browser signer',wanted);}
function bunker(){const wanted=intent();modal('<h2>Connect nsecBunker</h2><p>Paste a bunker:// link from your remote signer. Keep its secret private.</p><form id="bunkerForm" data-intent="'+wanted+'"><label for="bunkerUri">Connection link</label><input id="bunkerUri" type="password" autocomplete="off" required><button class="dark">Connect remote signer</button></form><div id="bunkerApproval"></div>');}
async function lightning(){const wanted=intent();const epoch=modal('<h2>Continue with Lightning</h2><p id="lnstatus">Preparing your wallet challenge…</p><div id="lnqr"></div><p id="lnlink"></p><p>No payment is requested. Use a wallet that supports LNURL-auth.</p>');const c=await api('/api/nosternity/auth/lightning/challenge',{intent:wanted});if(epoch!==dialogEpoch)return;
 $('#lnstatus').textContent=wanted==='signup'?'Scan to create your Lightning account.':'Scan to sign in with your Lightning identity.';
 new window.QRCode($('#lnqr'),{text:c.lnurl,width:210,height:210});if(/^lnurl[0-9a-z]+$/i.test(c.lnurl))$('#lnlink').innerHTML='<a href="lightning:'+esc(c.lnurl)+'">Open wallet ↗</a>';
 async function poll(){if(epoch!==dialogEpoch)return;if(Date.now()/1000>c.expires_at){$('#lnstatus').textContent='Challenge expired. Close this dialog and try again.';return;}
  try{const s=await authenticating(()=>api('/api/nosternity/auth/lightning/poll',{challenge_id:c.challenge_id}));if(epoch!==dialogEpoch)return;if(s.status==='pending'){pollTimer=setTimeout(poll,2500);return;}state.session=s;await state.signer?.close?.();state.signer=null;close();await restore();await navigate('settings');toast('Lightning account connected.');}catch(e){fail(e);}}
 pollTimer=setTimeout(poll,2500);
}
function damageLogin(){const wanted=intent();modal('<h2>Your DamageBDD account</h2><p>Sign in to connect DamageBDD services. Your Nostr session stays primary if already connected.</p><form id="damageForm" data-intent="'+wanted+'"><label for="damageMode">Action</label><select id="damageMode"><option value="login">Sign in</option><option value="signup">Create DamageBDD account</option><option value="recovery">Recover account</option></select><label for="email">Email</label><input id="email" type="email" autocomplete="username" required><div id="passwordRow"><label for="password">Password</label><input id="password" type="password" autocomplete="current-password" required></div><button class="dark">Continue</button></form>');}
async function savePrefs(next){if(!state.session)throw Error('Sign in to save feed preferences.');const epoch=state.epoch;const account=await api('/api/nosternity/preferences',next);if(epoch===state.epoch)state.account=account;chrome();}
function filters(){const p=prefs();modal('<h2>A little less noise.</h2><p>Simple, reversible filters applied by your server to each loaded batch.</p><form id="filtersForm"><div class="setting"><label for="spam">Filter obvious promotional spam</label><input id="spam" type="checkbox" '+(p.spam?'checked':'')+'></div><div class="setting"><label for="duplicates">Hide repeated text</label><input id="duplicates" type="checkbox" '+(p.duplicates?'checked':'')+'></div><label for="words">Muted words, comma separated</label><input id="words" value="'+esc(p.words.join(', '))+'"><p>'+p.muted.length+' authors muted.</p><button type="button" data-action="unmute">Clear muted authors</button><button class="dark">Save preferences</button></form>');}
async function ensureSigner(){if(state.session?.provider!=='nostr')throw Error(messages.nostr_login_required);if(!state.signer)throw Error('Reconnect your browser signer or nsecBunker in Key & signing.');const pub=await deadline(state.signer.getPublicKey());if(pub!==state.session.subject)throw Error('Your signer identity differs from this session. Sign in again.');return pub;}
async function publish(kind,content,tags=[]){const pub=await ensureSigner();const e=await deadline(state.signer.signEvent({kind,content,tags,created_at:Math.floor(Date.now()/1000)}));if(!verifyEvent(e)||e.pubkey!==pub||e.kind!==kind||e.content!==content||JSON.stringify(e.tags)!==JSON.stringify(tags))throw Error('Unexpected event returned by signer.');const r=await api('/api/nosternity/events',e);if(r.accepted!==true)throw Error('Relay did not accept the event.');return r;}
function nwc(){modal('<h2>Bring your Lightning wallet.</h2><p>Set your permissions and spending budget in your wallet, then paste its NWC connection here.</p><form id="nwcForm"><label for="nwcUri">Private connection link</label><input id="nwcUri" type="password" autocomplete="off" required placeholder="nostr+walletconnect://…"><button class="dark">Connect wallet</button></form>');}
async function balance(){if(!state.wallet)throw Error('Connect a Lightning wallet first.');const r=await state.wallet.request('get_balance');if(!Number.isFinite(r?.balance))throw Error('Invalid wallet balance.');state.balance=r.balance/1000;walletView();}
function requireWallet(){if(!state.wallet)throw Error('Connect a Lightning wallet first.');}
function requireDamage(){if(!state.damage||state.damage.mode!=='custodial')throw Error(messages.damage_login_required);}
async function sessions(){requireDamage();const r=await api('/api/nwc/sessions',{});modal('<h2>DamageBDD wallet connections</h2>'+(r.sessions||[]).map(s=>'<div class="setting"><span class="mono">'+esc(short(s.client_pubkey))+'</span><button data-action="revoke" data-key="'+esc(s.client_pubkey)+'" '+(s.revoked?'disabled':'')+'>'+(s.revoked?'Revoked':'Revoke')+'</button></div>').join(''));}
const actions={close,login:authDialog,nostrLogin,bunker,signProof,lightning,damageLogin,filters,nwc,balance,sessions,
 refresh:()=>navigate(state.page),
 compose:async()=>{await ensureSigner();modal('<h2>What’s on your mind?</h2><form id="composeForm"><label for="note">Public note</label><textarea id="note" maxlength="16000" required></textarea><button class="dark">Sign & publish</button></form>');},
 profile:async()=>{await ensureSigner();const r=await api('/api/nostr/search',{filters:[{kinds:[0],authors:[state.session.subject],limit:1}]});let p={};try{p=JSON.parse(r.results[0]?.event.content||'{}');}catch{}modal('<h2>Your Nostr profile</h2><p>Updates are public signed profile events.</p><form id="profileForm"><label for="name">Display name</label><input id="name" maxlength="100" value="'+esc(p.name||'')+'"><label for="about">About you</label><textarea id="about" maxlength="2000">'+esc(p.about||'')+'</textarea><button class="dark">Sign & update profile</button></form>');$('#profileForm')._profile=p;},
 follow:async()=>{await ensureSigner();modal('<h2>Follow someone</h2><form id="followForm"><label for="followKey">Nostr public key or npub</label><input id="followKey" required><p>This updates your contact list from the latest kind-3 event on this relay. Connect the relay holding your full list before adding people.</p><button class="dark">Review contact list</button></form>');},
 bookmark:async el=>{const ids=prefs().bookmarks;await savePrefs({...prefs(),bookmarks:ids.includes(el.dataset.id)?ids.filter(x=>x!==el.dataset.id):[el.dataset.id,...ids].slice(0,100)});await navigate(state.page);},
 mute:async el=>{const e=state.events.find(e=>e.id===el.dataset.id);if(!e)return;await savePrefs({...prefs(),muted:[...new Set([...prefs().muted,e.pubkey])].slice(0,200)});await navigate(state.page);},
 unmute:async()=>{await savePrefs({...prefs(),muted:[]});filters();},
 details:el=>{const e=state.events.find(e=>e.id===el.dataset.id);if(e)modal('<h2>Signed event</h2><p>A valid signature proves authorship, not the truth of the content.</p><pre class="mono" style="white-space:pre-wrap;max-height:50vh;overflow:auto">'+esc(JSON.stringify(e,null,2))+'</pre>');},
 disconnectWallet:()=>{state.wallet?.close();state.wallet=null;state.balance=null;walletView();toast('Disconnected locally. Revoke the connection in your wallet to remove permission.');},
 pay:()=>{requireWallet();modal('<h2>Pay a Lightning invoice</h2><form id="payForm"><label for="invoice">BOLT11 invoice</label><textarea id="invoice" required></textarea><button class="dark">Review payment</button></form>');},
 receive:()=>{requireWallet();modal('<h2>Receive sats</h2><form id="receiveForm"><label for="amount">Amount in sats</label><input id="amount" type="number" min="1" max="100000000" required><label for="description">Description</label><input id="description" maxlength="150"><button class="dark">Create invoice</button></form>');},
 mint:()=>{requireDamage();modal('<h2>Create a budgeted connection</h2><form id="mintForm"><label for="single">Maximum per payment (sats)</label><input id="single" type="number" min="1" max="100000000" value="1000" required><label for="total">Total budget (sats)</label><input id="total" type="number" min="1" max="100000000" value="10000" required><p>This creates a spend-capable connection using DamageBDD’s configured relays.</p><button class="dark">Create connection</button></form>');},
 revoke:el=>{const key=el.dataset.key;if(!validPubkey(key))throw Error('Invalid connection key.');modal('<h2>Revoke wallet access?</h2><p class="mono">'+key+'</p><button class="dark" data-action="confirmRevoke" data-key="'+key+'">Confirm revocation</button>');},
 confirmRevoke:async el=>{requireDamage();const r=await api('/api/nwc/revoke',{client_pubkey:el.dataset.key});if(r.revoked!==true)throw Error('Revocation needs a ledger signature in DamageBDD. Access is not yet confirmed revoked.');await sessions();},
 signout:async()=>{const results=await authenticating(()=>Promise.allSettled([api('/api/nosternity/auth/logout',{}),api('/accounts/session/logout',{})]));await state.signer?.close?.();state.signer=null;actions.disconnectWallet();state.session=null;state.damage=null;state.account=null;close();chrome();await navigate('explore');if(results.some(r=>r.status==='rejected'))throw Error('Local connections closed, but server logout was not confirmed. Retry when the service is available.');toast('Signed out.');}
};
const forms={
 searchForm:async()=>{state.query=$('#search').value.trim();await navigate(state.page);},
 bunkerForm:async form=>{const uri=$('#bunkerUri').value.trim();$('#bunkerUri').value='';const epoch=dialogEpoch;let result;try{result=await connectBunker(uri,url=>{try{const u=new URL(url);if(u.protocol==='https:'&&$('#bunkerApproval'))$('#bunkerApproval').innerHTML='<a href="'+esc(u.href)+'" target="_blank" rel="noopener noreferrer">Review approval at '+esc(u.host)+' ↗</a>';}catch{}});if(epoch!==dialogEpoch){await result.signer.close();return;}await prepareNostr(result.signer,'Remote signer · NIP-46',form.dataset.intent);}catch(e){await result?.signer.close();throw e;}},
 damageForm:async form=>{const mode=$('#damageMode').value,email=$('#email').value.trim(),password=$('#password').value;$('#password').value='';const body=mode==='login'?{username:email,password}:{email};const r=await authenticating(()=>api('/accounts/'+mode,body));
  if(mode!=='login'){modal('<h2>Check your email</h2><p>'+esc(r.message||'Continue using the confirmation or recovery link sent by DamageBDD.')+'</p><button class="dark" data-action="damageLogin">Back to sign in</button>');return;}
  state.damage=r;if(!state.session)state.session=await authenticating(()=>api('/api/nosternity/auth/damage',{intent:form.dataset.intent}));close();await restore();await navigate('settings');toast('DamageBDD connected.');},
 filtersForm:async()=>{const p={...prefs(),spam:$('#spam').checked,duplicates:$('#duplicates').checked,words:$('#words').value.split(',').map(s=>s.trim()).filter(Boolean)};await savePrefs(p);close();await navigate(state.page);},
 composeForm:async()=>{const text=$('#note').value.trim();if(!text||new TextEncoder().encode(text).length>16000)throw Error('Enter 1–16,000 bytes of text.');await publish(1,text);close();await navigate('account');toast('Note accepted by this relay.');},
 profileForm:async form=>{const p={...form._profile,name:$('#name').value.trim(),about:$('#about').value.trim()};await publish(0,JSON.stringify(p));close();toast('Profile update accepted by this relay.');},
 followForm:async()=>{const key=publicKey($('#followKey').value);const r=await api('/api/nostr/search',{filters:[{kinds:[3],authors:[state.session.subject],limit:1}]});const prev=r.results[0]?.event;const tags=prev?.tags||[];if(tags.some(t=>t[0]==='p'&&t[1]===key))throw Error('Already following this key on this relay.');if(tags.length>=255)throw Error('Contact list is at this relay’s tag limit.');const next=[...tags,['p',key]];modal('<h2>Update your contact list?</h2><p>Preserves '+tags.filter(t=>t[0]==='p').length+' contacts from this relay and adds:</p><p class="mono">'+esc(npubEncode(key))+'</p><form id="confirmFollow"><button class="dark">Sign & publish contact list</button></form>');$('#confirmFollow')._event={tags:next,content:prev?.content||''};},
 confirmFollow:async form=>{await publish(3,form._event.content,form._event.tags);close();state.scope='following';await navigate('explore');},
 nwcForm:async()=>{const uri=$('#nwcUri').value.trim();$('#nwcUri').value='';const epoch=dialogEpoch;let w;try{w=new Wallet(uri);await w.connect();}catch(e){w?.close();throw e;}if(epoch!==dialogEpoch){w.close();return;}state.wallet?.close();state.wallet=w;state.balance=null;close();await navigate('wallet');if(w.methods.includes('get_balance'))await balance();},
 payForm:async()=>{const invoice=$('#invoice').value.trim().replace(/^lightning:/i,'');if(!/^ln(bc|tb|bcrt)[0-9a-z]+$/i.test(invoice))throw Error('Enter a BOLT11 invoice.');modal('<h2>Confirm payment</h2><p>Check the invoice and its amount in your wallet. Payment uses this connection’s permissions.</p><p class="mono" style="max-height:180px;overflow:auto">'+esc(invoice)+'</p><form id="confirmPayment"><div class="row"><input type="checkbox" id="confirmPay" required><label for="confirmPay">I have checked this invoice and want to pay it.</label></div><button class="dark">Pay this invoice</button></form>');$('#confirmPayment')._invoice=invoice;},
 confirmPayment:async form=>{requireWallet();const r=await state.wallet.request('pay_invoice',{invoice:form._invoice});if(!r?.preimage)throw Error('No payment proof returned. Check your wallet before retrying.');state.balance=null;modal('<h2>Payment sent</h2><p>Your wallet returned this proof:</p><p class="mono">'+esc(r.preimage)+'</p>');walletView();},
 receiveForm:async()=>{requireWallet();const sats=Number($('#amount').value);if(!Number.isSafeInteger(sats)||sats<1||sats>1e8)throw Error('Enter a whole amount from 1 to 100,000,000 sats.');const r=await state.wallet.request('make_invoice',{amount:sats*1000,description:$('#description').value});if(!/^ln(bc|tb|bcrt)[0-9a-z]+$/i.test(r?.invoice))throw Error('Wallet did not return a valid invoice.');modal('<h2>Ready to receive '+sats.toLocaleString()+' sats</h2><div id="invoiceQr"></div><p class="mono">'+esc(r.invoice)+'</p><p>Invoice created. Payment has not been confirmed.</p>');new window.QRCode($('#invoiceQr'),{text:r.invoice,width:200,height:200});},
 mintForm:async()=>{requireDamage();const single=Number($('#single').value),total=Number($('#total').value);if(!Number.isSafeInteger(single)||!Number.isSafeInteger(total)||single<1||total<single||total>1e8)throw Error('Total budget must cover the per-payment limit.');const r=await api('/api/nwc/mint',{max_single_sat:single,max_total_sat:total});if(r.usable!==true||!r.nwc_uri)throw Error('Finish the required ledger registration in DamageBDD first.');modal('<h2>Connection created</h2><p>This private link grants wallet access within your budget. It is cleared when you close this dialog.</p><textarea id="mintedUri" readonly aria-label="Private wallet connection"></textarea>');$('#mintedUri').value=r.nwc_uri;}
};
document.addEventListener('click',async e=>{const el=e.target.closest('button');if(!el)return;if(authBusy){e.preventDefault();return;}try{
 if(el.dataset.page){if(el.dataset.page==='explore')state.scope='global';close();await navigate(el.dataset.page);}else if(el.dataset.topic!==undefined){state.query=el.dataset.topic;state.scope='global';await navigate('explore');}
 else if(el.dataset.scope){state.scope=el.dataset.scope;await navigate('explore');}else if(actions[el.dataset.action]){el.disabled=true;try{await actions[el.dataset.action](el);}finally{el.disabled=false;}}
 }catch(err){fail(err);}});
document.addEventListener('submit',async e=>{if(!forms[e.target.id])return;e.preventDefault();if(authBusy)return;const button=e.target.querySelector('button:not([type]),button[type=submit]');if(button)button.disabled=true;try{await forms[e.target.id](e.target);}catch(err){fail(err);}finally{if(button)button.disabled=false;}});
document.addEventListener('change',e=>{if(e.target.id==='kind'){state.kind=e.target.value;navigate(state.page).catch(fail);}if(e.target.id==='damageMode'){const login=e.target.value==='login';$('#passwordRow').hidden=!login;$('#password').required=login;}});
$('#modal').addEventListener('cancel',e=>{e.preventDefault();close();});
window.addEventListener('hashchange',()=>{const page=location.hash.slice(1);if(!authBusy&&labels[page]&&page!==state.page)navigate(page).catch(fail);});
(async()=>{try{const options=await api('/api/nosternity/auth/options');if(options.origin!==location.origin)throw Error(messages.origin_rejected);await restore();await navigate(labels[location.hash.slice(1)]?location.hash.slice(1):'explore');}catch(e){$('#content').innerHTML=blank('Dashboard setup needs attention',e.message);$('#mode').textContent='○ Service unavailable';}})();
