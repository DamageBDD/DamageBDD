import {invoiceQrSvg} from "/static/js/vendor/ecai-qrcode.js?v=personalities-v1";

/* Public catalogue; account-isolated orders. The server alone verifies settlement and minting. */
export function initPersonalities({request, currentToken, managedSession, openLogin}) {
  const $ = id => document.getElementById(id);
  const root = document.querySelector('[data-panel="personalities"]');
  if (!root) return {refresh:async()=>{}, reset(){}, accessChanged(){}, setVisible(){}, dispose(){}};
  const state = {epoch:0, visible:false, disposed:false, loading:false, busy:false, pollBusy:false,
    catalogue:null, orders:[], selected:null, order:null, keys:new Map(), controllers:new Set(),
    qrUrl:null, qrInvoice:null, timer:null, clock:null, opener:null, selectionSerial:0};
  const base = '/ecai/personalities';
  const activeStatuses = new Set(['invoice_pending','pending','paid','mint_pending']);
  const labels = {invoice_pending:'Preparing invoice',pending:'Awaiting payment',paid:'Payment verified',mint_pending:'Mint in progress',minted:'Edition minted',expired:'Invoice expired',cancelled:'Invoice not created'};
  const el = (tag, text, cls) => {const n=document.createElement(tag);if(text!==undefined)n.textContent=String(text);if(cls)n.className=cls;return n;};
  const sats = n => Number.isSafeInteger(n)&&n>=0 ? `${n.toLocaleString()} sats` : 'Price unavailable';
  const esc = encodeURIComponent;
  const status = (message='', error=false, checkout=false) => {const n=$(checkout?'personalityCheckoutStatus':'personalitiesStatus');n.textContent=message;n.dataset.error=String(error);};
  function message(error) {return typeof error?.body?.error==='string'?error.body.error:typeof error?.message==='string'?error.message:'Request unavailable. Please retry.';}
  async function act(fn,checkout=false) {const epoch=state.epoch;try {return await fn();}catch(e){if(e.name!=='AbortError'&&epoch===state.epoch&&!state.disposed)status(message(e),true,checkout);}}
  function newKey() {const bytes=crypto.getRandomValues(new Uint8Array(16));return 'personality-'+Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');}
  async function api(path='',body) {
    if(path&&!managedSession())throw new Error('Sign in with a managed account to collect a personality.');
    const epoch=state.epoch, token=currentToken(), controller=new AbortController();state.controllers.add(controller);
    try {
      const response=await request(base+path,{signal:controller.signal,ignoreAuth:true,...(body===undefined?{}:{method:'POST',body})});
      if(epoch!==state.epoch||token!==currentToken()||state.disposed)throw new DOMException('Session changed','AbortError');
      if(response.ok!==true)throw new Error(typeof response.error==='string'?response.error:'Invalid personality response.');
      return response.data;
    } finally {state.controllers.delete(controller);}
  }
  function button(label,fn,cls='button button-outline button-sm') {const b=el('button',label,cls);b.type='button';b.addEventListener('click',()=>void act(fn));return b;}
  function fields(host,rows) {const dl=el('dl');for(const [k,v] of rows){if(v===undefined||v===null||v==='')continue;dl.append(el('dt',k),el('dd',typeof v==='object'?JSON.stringify(v):v));}host.replaceChildren(dl);}
  function itemsAvailable(item) {return item.available!==false && item.available!==0;}
  function renderCatalogue() {
    const host=$('personalityCatalogue');host.replaceChildren();const cat=state.catalogue;
    if(!cat||!Array.isArray(cat.items)||!cat.items.length){host.append(el('div',cat?.enabled===false?'The collection is not open yet.':'No personalities are available yet.','personality-catalogue-empty'));return;}
    cat.items.forEach((p,i)=>{
      const card=el('article',undefined,'personality-card'),art=el('div',undefined,'personality-card-art');art.setAttribute('aria-hidden','true');
      const monogram=String(p.name||'ECAI').split(/\s+/).map(x=>x[0]).filter(Boolean).slice(0,2).join('');
      art.append(el('span',`ECAI / ${String(i+1).padStart(2,'0')}`,'personality-card-index'),el('span',monogram,'personality-monogram'));
      const body=el('div',undefined,'personality-card-body');body.append(el('h3',p.name||p.id));
      if(p.tagline)body.append(el('p',p.tagline,'personality-tagline'));if(p.description)body.append(el('p',p.description));
      if(Array.isArray(p.traits)){const traits=el('div',undefined,'personality-traits');p.traits.slice(0,6).forEach(t=>traits.append(el('span',t)));body.append(traits);}
      const edition=Number.isSafeInteger(p.edition_limit)?`${p.edition_limit.toLocaleString()} editions`:'Edition details in package';
      const available=typeof p.available==='number'?` · ${p.available.toLocaleString()} available`:!itemsAvailable(p)?' · Sold out':'';
      body.append(el('div',`${edition}${available}${p.version?' · v'+p.version:''}`,'personality-card-meta'));
      const foot=el('div',undefined,'personality-card-footer');foot.append(el('span',sats(p.price_sats),'personality-price'));
      const buy=button(itemsAvailable(p)?'View edition ↗':'View edition',()=>selectPersonality(p));buy.dataset.personality=p.id;foot.append(buy);body.append(foot);card.append(art,body);host.append(card);
    });
  }
  function renderOrders() {
    const host=$('personalityOrders');host.replaceChildren();if(!managedSession())return;
    if(!state.orders.length){host.append(el('p','Your purchased editions and pending invoices will appear here.','context-hint'));return;}
    for(const order of state.orders){const row=el('div',undefined,'personality-order-row'),info=el('div');info.append(el('strong',order.name||state.catalogue?.items?.find(x=>x.id===order.personality_id)?.name||order.personality_id),el('p',`${sats(order.price_sats)} · ${labels[order.status]||order.status} · ${order.id}`));row.append(info,button(order.status==='minted'?'Receipt':'Resume',()=>openOrder(order.id)));host.append(row);}
  }
  function accessChanged() {$('personalitySignInNotice').hidden=managedSession();if(!managedSession())$('personalityOrders').replaceChildren();if(state.visible)void act(refresh);}
  async function refresh() {
    $('personalitySignInNotice').hidden=managedSession();if(state.loading||state.disposed)return;state.loading=true;const epoch=state.epoch;
    try {
      const cat=await api();state.catalogue=cat;renderCatalogue();
      status(cat.enabled===false?'The collection is not open yet.':cat.checkout_enabled===false?'Browse the collection. Lightning checkout is currently unavailable.':`${cat.items?.length||0} personalities · Pay with your Lightning wallet`);
      if(managedSession()){const orders=await api('/orders');state.orders=Array.isArray(orders)?orders:orders.items||orders.orders||[];renderOrders();}
      else renderOrders();
      const deepLink=new URLSearchParams(location.search).get('personality');
      if(deepLink&&!state.selected&&!$('personalityCheckout').open){const p=cat.items?.find(x=>x.id===deepLink);if(p)await selectPersonality(p);}
    } finally {if(epoch===state.epoch)state.loading=false;}
  }
  function showDialog() {state.opener=document.activeElement;if(!$('personalityCheckout').open)$('personalityCheckout').showModal();}
  function closeDialog() {$('personalityCheckout').close();state.selectionSerial++;state.opener?.focus?.();}
  function clearQr() {if(state.qrUrl)URL.revokeObjectURL(state.qrUrl);state.qrUrl=null;state.qrInvoice=null;$('personalityInvoiceQr').removeAttribute('src');$('personalityInvoiceQr').hidden=true;}
  async function selectPersonality(personality) {
    state.selectionSerial++;state.selected=personality;state.order=null;clearQr();status('',false,true);
    $('personalityCheckoutTitle').textContent=personality.name||personality.id;
    $('personalityCheckoutDescription').textContent=personality.description||personality.tagline||'';
    fields($('personalityCheckoutDetails'),[['Edition price',sats(personality.price_sats)],['Version',personality.version],['Licence',personality.license],['Package SHA-256',personality.package_sha256]]);
    $('personalityCheckoutForm').reset();$('personalityCheckoutForm').hidden=false;$('personalityPayment').hidden=true;
    const enabled=state.catalogue?.enabled!==false&&state.catalogue?.checkout_enabled===true&&itemsAvailable(personality);
    $('personalityCreateInvoice').type=managedSession()?'submit':'button';$('personalityCreateInvoice').textContent=managedSession()?'Create Lightning invoice':'Sign in to collect';$('personalityCreateInvoice').disabled=!enabled;$('personalityRecipient').disabled=!enabled;$('personalityAcceptLicense').disabled=!enabled;
    if(!enabled)status(!itemsAvailable(personality)?'This edition is sold out.':'Checkout is not available for this edition.',false,true);
    else if(!managedSession())status('Sign in with your managed account to create an invoice.',false,true);
    showDialog();
    const existing=state.orders.find(x=>x.personality_id===personality.id&&activeStatuses.has(x.status));
    if(existing&&managedSession())await openOrder(existing.id);
  }
  async function openOrder(id) {
    if(!managedSession()){openLogin('Sign in with your managed account to resume this purchase.');return;}
    const serial=++state.selectionSerial;const order=await api('/orders/'+esc(id));if(serial!==state.selectionSerial)return;
    state.selected=state.catalogue?.items?.find(p=>p.id===order.personality_id)||null;
    state.order=order;showDialog();renderOrder();
  }
  function expiryMs(order) {const n=order?.expires_at;if(typeof n==='number')return n<1e12?n*1000:n;if(typeof n==='string'){const parsed=Date.parse(n);return Number.isFinite(parsed)?parsed:null;}return null;}
  function invoiceUsable(order) {const expiry=expiryMs(order);return order?.status==='pending'&&typeof order.bolt11==='string'&&/^ln(?:bc|tb|bcrt)[0-9a-z]+$/i.test(order.bolt11)&&(expiry===null||expiry>Date.now());}
  function updateExpiry() {
    const o=state.order;if(!o)return;const expires=expiryMs(o);if(expires===null){$('personalityInvoiceExpiry').textContent='Expiry supplied by your Lightning wallet.';return;}
    const remaining=Math.ceil((expires-Date.now())/1000);
    $('personalityInvoiceExpiry').textContent=remaining>0?`Invoice expires in ${Math.floor(remaining/60)}:${String(remaining%60).padStart(2,'0')}`:'Invoice time elapsed. Checking the server for final payment status.';
    if(remaining<=0&&o.status==='pending'){$('personalityInvoiceArea').hidden=true;$('personalityOpenWallet').removeAttribute('href');$('personalityCopyInvoice').disabled=true;status('Invoice time elapsed. Use “Check payment & mint” before starting another purchase.',false,true);}
  }
  function renderOrder() {
    const o=state.order;if(!o)return;
    $('personalityCheckoutTitle').textContent=o.name||state.selected?.name||o.personality_id;
    $('personalityCheckoutDescription').textContent=state.selected?.tagline||'Your edition and its verified purchase record.';
    $('personalityCheckoutDetails').replaceChildren();$('personalityCheckoutForm').hidden=true;$('personalityPayment').hidden=false;
    $('personalityOrderAmount').textContent=sats(o.price_sats);$('personalityOrderState').textContent=labels[o.status]||o.status;$('personalityOrderState').dataset.status=o.status;
    if(['minted','expired','cancelled'].includes(o.status))state.keys.delete(JSON.stringify([o.personality_id,o.recipient]));
    const paid=['paid','mint_pending','minted'].includes(o.status);
    $('personalityStepInvoice').dataset.done=String(o.status!=='invoice_pending');$('personalityStepPaid').dataset.done=String(paid);$('personalityStepMinted').dataset.done=String(o.status==='minted');
    $('personalityDownload').hidden=o.status!=='minted';$('personalityRetryPurchase').hidden=o.status!=='cancelled'||!state.selected;$('personalityReconcile').disabled=state.pollBusy||state.busy;
    const usable=invoiceUsable(o);$('personalityInvoiceArea').hidden=!usable;$('personalityCopyInvoice').disabled=!usable;
    $('personalityInvoiceText').value=usable?o.bolt11:'';
    if(usable){$('personalityOpenWallet').href='lightning:'+o.bolt11;
      if(state.qrInvoice!==o.bolt11){clearQr();try{state.qrUrl=URL.createObjectURL(new Blob([invoiceQrSvg(o.bolt11)],{type:'image/svg+xml'}));state.qrInvoice=o.bolt11;$('personalityInvoiceQr').src=state.qrUrl;$('personalityInvoiceQr').hidden=false;$('personalityQrStatus').hidden=true;}catch(e){$('personalityQrStatus').hidden=false;$('personalityQrStatus').textContent='QR unavailable. Copy the invoice or open your wallet.';}}
    }else{clearQr();$('personalityOpenWallet').removeAttribute('href');}
    const notices={invoice_pending:'Preparing your invoice. This order is saved; you can return to it.',pending:'Waiting for server-confirmed Lightning payment.',paid:'Payment verified. Your edition is waiting to be minted.',mint_pending:'Payment verified. Minting is in progress; your order remains saved.',cancelled:'No invoice was issued and no payment was requested. You can start a new purchase when checkout is available.',minted:'Your edition is minted. Download your personality and save its receipt.',expired:'This invoice expired. Any late payment is checked by the server; keep this order ID for support.'};
    status((notices[o.status]||'Order state received from the server.')+(typeof o.last_error==='string'?' '+o.last_error:''),false,true);updateExpiry();
    fields($('personalityReceipt'),[['Order',o.id],['Recipient',o.recipient],['Token ID',o.token_id],['NFT contract',o.contract_id],['Mint transaction',o.tx_hash],['Package SHA-256',o.package_sha256]]);
    const index=state.orders.findIndex(x=>x.id===o.id);if(index>=0)state.orders[index]=o;else state.orders.unshift(o);renderOrders();
  }
  async function createInvoice(event) {
    event.preventDefault();if(state.busy||!state.selected)return;
    if(!managedSession()){closeDialog();openLogin('Sign in with your managed account to collect this edition.');return;}
    if(!state.catalogue?.checkout_enabled||!itemsAvailable(state.selected))throw new Error('Checkout is currently unavailable.');
    const recipient=$('personalityRecipient').value.trim();if(!/^ak_[1-9A-HJ-NP-Za-km-z]{32,60}$/.test(recipient))throw new Error('Enter a valid Aeternity account address beginning with ak_.');
    if(!$('personalityAcceptLicense').checked)throw new Error('Review and accept the licence before creating an invoice.');
    const signature=JSON.stringify([state.selected.id,recipient]);if(!state.keys.has(signature))state.keys.set(signature,newKey());
    const key=state.keys.get(signature),epoch=state.epoch,serial=state.selectionSerial;
    state.busy=true;$('personalityCreateInvoice').disabled=true;$('personalityRecipient').disabled=true;$('personalityAcceptLicense').disabled=true;status('Creating your invoice…',false,true);
    try {const order=await api('/orders',{personality_id:state.selected.id,recipient,idempotency_key:key});
      if(serial!==state.selectionSerial)return;state.order=order;renderOrder();
    } finally {if(epoch===state.epoch){state.busy=false;$('personalityReconcile').disabled=state.pollBusy;$('personalityCreateInvoice').disabled=false;$('personalityRecipient').disabled=false;$('personalityAcceptLicense').disabled=false;}}
  }
  async function reconcile() {
    if(!state.order||state.pollBusy||!managedSession())return;const id=state.order.id,serial=state.selectionSerial,epoch=state.epoch;state.pollBusy=true;$('personalityReconcile').disabled=true;
    try {const order=await api('/orders/'+esc(id)+'/reconcile',{});if(serial===state.selectionSerial&&state.order?.id===id){state.order=order;renderOrder();}}
    finally {if(epoch===state.epoch){state.pollBusy=false;$('personalityReconcile').disabled=false;}}
  }
  function saveBlob(blob,name) {const url=URL.createObjectURL(blob),a=el('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
  async function download() {
    const order=state.order;if(!order||order.status!=='minted'||!managedSession())return;
    const epoch=state.epoch,token=currentToken(),controller=new AbortController();state.controllers.add(controller);$('personalityDownload').disabled=true;
    try {const response=await fetch(base+'/orders/'+esc(order.id)+'/package',{headers:{Authorization:'Bearer '+token,Accept:'application/json'},credentials:'include',mode:'same-origin',redirect:'error',cache:'no-store',signal:controller.signal});
      if(!response.ok)throw new Error('Package download is unavailable. Refresh your purchase and retry.');
      const bytes=await response.arrayBuffer();if(epoch!==state.epoch||token!==currentToken())throw new DOMException('Session changed','AbortError');
      if(!crypto.subtle)throw new Error('A secure HTTPS connection is required to verify this package.');
      if(!/^[a-f0-9]{64}$/i.test(order.package_sha256||''))throw new Error('The order has no valid package checksum. Download stopped.');
      const digest=await crypto.subtle.digest('SHA-256',bytes);
      const actual=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
      if(actual!==order.package_sha256.toLowerCase())throw new Error('Package checksum mismatch. Download stopped; contact the operator with your order ID.');
      if(epoch!==state.epoch||token!==currentToken())throw new DOMException('Session changed','AbortError');
      saveBlob(new Blob([bytes],{type:'application/json'}),`ecai-personality-${String(order.id).replace(/[^a-zA-Z0-9_-]/g,'')}.json`);status('Personality package verified and downloaded.',false,true);
    } finally {state.controllers.delete(controller);if(epoch===state.epoch)$('personalityDownload').disabled=false;}
  }
  function receipt() {if(!state.order)return;const {bolt11,...record}=state.order;saveBlob(new Blob([JSON.stringify({receipt_version:1,observed_at:new Date().toISOString(),order:record},null,2)],{type:'application/json'}),`ecai-personality-receipt-${String(record.id).replace(/[^a-zA-Z0-9_-]/g,'')}.json`);}
  function reset() {
    state.epoch++;state.selectionSerial++;for(const c of state.controllers)c.abort();state.controllers.clear();state.orders=[];state.order=null;state.selected=null;state.keys.clear();state.loading=false;state.busy=false;state.pollBusy=false;clearQr();
    if($('personalityCheckout').open)$('personalityCheckout').close();$('personalityCheckoutForm').reset();$('personalityInvoiceText').value='';$('personalityRecipient').value='';$('personalityOpenWallet').removeAttribute('href');$('personalityReceipt').replaceChildren();$('personalityCheckoutDetails').replaceChildren();$('personalityOrders').replaceChildren();$('personalityPayment').hidden=true;$('personalitySignInNotice').hidden=managedSession();status('',false,true);
  }
  function setVisible(visible) {state.visible=visible;if(!visible&&$('personalityCheckout').open)closeDialog();if(visible)void act(refresh);}
  function dispose() {state.disposed=true;clearInterval(state.timer);clearInterval(state.clock);reset();}
  $('personalitiesRefresh').addEventListener('click',()=>void act(refresh));$('personalitySignIn').addEventListener('click',()=>openLogin('Sign in with your managed account to collect an edition.'));
  $('personalityCloseCheckout').addEventListener('click',closeDialog);$('personalityCheckout').addEventListener('cancel',()=>{state.selectionSerial++;});
  $('personalityCreateInvoice').addEventListener('click',()=>{if(!managedSession()){closeDialog();openLogin('Sign in with your managed account to collect this edition.');}});
  $('personalityCheckoutForm').addEventListener('submit',event=>void act(()=>createInvoice(event),true));
  $('personalityRetryPurchase').addEventListener('click',()=>{if(state.selected)void act(()=>selectPersonality(state.selected),true);});
  $('personalityReconcile').addEventListener('click',()=>void act(reconcile,true));$('personalityDownload').addEventListener('click',()=>void act(download,true));$('personalityReceiptDownload').addEventListener('click',receipt);
  $('personalityCopyInvoice').addEventListener('click',()=>void act(async()=>{if(!invoiceUsable(state.order))return;if(!navigator.clipboard?.writeText){$('personalityInvoiceText').focus();$('personalityInvoiceText').select();status('Select and copy the invoice below.',false,true);return;}await navigator.clipboard.writeText(state.order.bolt11);status('Invoice copied. Pay it once with your Lightning wallet.',false,true);},true));
  state.timer=setInterval(()=>{if(state.visible&&!document.hidden&&$('personalityCheckout').open&&activeStatuses.has(state.order?.status))void act(reconcile,true);},5000);
  state.clock=setInterval(()=>{if($('personalityCheckout').open)updateExpiry();},1000);
  return {refresh,reset,accessChanged,setVisible,dispose};
}
