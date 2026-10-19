const isStudio = document.body.dataset.themeMode === "studio";
const $ = (id) => document.getElementById(id);
const ui = { themes: [], selected: {} };
const apps = ["damage", "ecai", "nosternity", "erm", "bop"];
const setMessage = (message, bad = false) => {
  const target = $("notice"); target.textContent = message; target.dataset.error = String(bad);
};

async function api(path, options = {}) {
  const headers = { Accept: "application/json", ...(options.body ? {
    "Content-Type": "application/json", "x-damage-settings-action": "1"
  } : {}) };
  const response = await fetch(path, {
    credentials: "same-origin", cache: "no-store", method: options.body ? "POST" : "GET",
    headers, body: options.body ? JSON.stringify(options.body) : undefined
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.error || `HTTP ${response.status}`);
  return data.data ?? data;
}
function element(tag, attrs = {}, text = null) {
  const e = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => { if (k === "class") e.className = v; else e.setAttribute(k, v); });
  if (text !== null) e.textContent = String(text);
  return e;
}
function priceText(theme) {
  if (theme.builtin || (!theme.price_sats && !theme.price_damage)) return "Free · Built-in";
  const parts = [];
  if (theme.price_sats) parts.push(`${Number(theme.price_sats).toLocaleString()} sats`);
  if (theme.price_damage) {
    const v = (Number(theme.price_damage) / 1e8).toLocaleString(undefined, {maximumFractionDigits: 8});
    parts.push(`${v} DAMAGE`);
  }
  return parts.join(" / ");
}
function action(label, cb, variant = "compact") {
  const b = element("button", {type: "button", class: `button ${variant}`}, label);
  b.addEventListener("click", async () => {
    b.disabled = true;
    try { await cb(); } catch (e) { setMessage(e.message, true); }
    finally { b.disabled = false; }
  });
  return b;
}
function renderTheme(theme) {
  const t = theme.tokens;
  const card = element("article", {class: "theme-card"});
  const sample = element("div", {class: "sample"});
  Object.entries({bg: t.background, surface: t.surface, border: t.border, accent: t.accent, text: t.text})
    .forEach(([k, v]) => sample.style.setProperty(`--sample-${k}`, v));
  const miniNav = element("div", {class: "sample-sidebar"});
  for (let i=0; i<3; i++) miniNav.append(element("i"));
  const miniBody = element("div", {class: "sample-main"});
  miniBody.append(element("div"),element("div"),element("span"));
  sample.append(miniNav,miniBody);
  const info = element("div", {class: "theme-info"});
  info.append(element("h3", {}, theme.name),element("p", {}, theme.description || "Portable design system"));
  info.append(element("small", {}, priceText(theme)));
  info.append(element("small", {}, theme.cid ? `IPFS · ${theme.cid}` : "Available on this node"));
  const actions = element("div", {class: "theme-actions"});
  if (isStudio) actions.append(action("Select", () => {
    $("theme-key").value = theme.key; updatePreview();
    $("selection-form").scrollIntoView({behavior:"smooth",block:"center"});
  }, "compact primary"));
  if (!theme.builtin && theme.status === "pending_registration" && isStudio)
    actions.append(action("Reconcile", async () => { await api("/api/admin/themes", {body:{action:"reconcile",theme_key:theme.key}}); await refresh(); }));
  if (!theme.builtin && theme.status === "available") {
    if (theme.price_sats > 0) actions.append(action("Pay sats ⚡", () => buySats(theme), "compact primary"));
    if (theme.price_damage > 0) actions.append(action("Pay DAMAGE ◈", () => buyDamage(theme)));
  }
  card.append(sample,info,actions); return card;
}
function render() {
  const catalog = $("catalog"); catalog.replaceChildren();
  ui.themes.forEach(t => { if (t.tokens) catalog.append(renderTheme(t)); });
  if (!ui.themes.length) catalog.append(element("p", {}, "No themes available"));
  if (isStudio) {
    const sel = $("theme-key"); const previous = sel.value;
    sel.replaceChildren(...ui.themes.filter(t=>t.status === "available" || t.builtin)
      .map(t=>{const o=element("option",{value:t.key},t.name);return o;}));
    const stored = ui.selected[$("app").value];
    sel.value = previous && ui.themes.some(t => t.key === previous) ? previous : stored?.key || ui.themes[0]?.key || "";
    updateSelection();
    $("registry-id").textContent = ui.nft?.contract ?? "Contract not configured — publishing and paid purchases disabled";
  }
}
function showDialog(title, content) {
  const d=$("checkout"), el=$("checkout-content");
  el.replaceChildren(element("h2",{},title), content); d.showModal();
}
async function buySats(theme) {
  const order = await api("/api/themes/buy/sats", {body:{theme_key:theme.key}});
  const content = element("div");
  content.append(element("p",{},`Lightning invoice for ${theme.name}: ${Number(order.amount_msat)/1000} sats.`));
  content.append(element("p",{class:"checkout-invoice"},order.invoice));
  const pay = element("a",{href:`lightning:${order.invoice}`,class:"button primary"},"Open Lightning wallet");
  const status = element("p",{class:"checkout-status"},"Unpaid");
  content.append(pay, action("Copy invoice", () => navigator.clipboard.writeText(order.invoice)),status);
  content.append(action("Check payment & NFT", async () => {
    const next = await api("/api/themes/order/settle", {body:{order_id:order.order_id}});
    status.textContent = `Order: ${next.status}${next.token_id ? ` · AEX-141 token #${next.token_id}` : ""}`;
    if (next.status === "minted") await refresh();
  },"compact primary"));
  showDialog("Pay with Lightning", content);
}
async function buyDamage(theme) {
  const res = await api("/api/themes/buy/damage", {body:{theme_key:theme.key}});
  const content = element("div");
  content.append(element("p",{},res.status === "wallet_signature_required"
    ? "Sign an AEX-9 allowance and the NFT purchase transaction in your Aeternity wallet. This page cannot spend your wallet funds."
    : "Aeternity transaction submitted. Confirm NFT ownership on-chain before activating."));
  content.append(element("p",{class:"checkout-invoice"},JSON.stringify(res,null,2)));
  showDialog("Purchase with DAMAGE",content);
}
function currentTheme(){return ui.themes.find(t=>t.key===$("theme-key").value) || ui.themes[0];}
function updatePreview() {
  if (!isStudio) return;
  const t = currentTheme(); if (!t) return;
  const windowEl = $("live-preview");
  Object.entries({bg:t.tokens.background,surface:t.tokens.surface,text:t.tokens.text,
    muted:t.tokens.muted,accent:t.tokens.accent,border:t.tokens.border})
    .forEach(([k,v])=>windowEl.style.setProperty(`--preview-${k}`,v));
  $("preview-name").textContent=$("brand-name").value || t.branding?.name || "DamageBDD";
  $("preview-tagline").textContent=$("brand-tagline").value || t.branding?.tagline || "Verification workspace";
  $("preview-meta").textContent=`${t.key} · ${priceText(t)} · ${$("app").value}`;
}
function updateSelection() {
  if (!isStudio) return;
  const s = ui.selected[$("app").value] || {};
  const b = s.branding || {};
  if (s.key && ui.themes.some(t=>t.key===s.key)) $("theme-key").value=s.key;
  $("nft-token").value=b.license?.token_id ?? 0;
  $("brand-name").value=b.name || "";
  $("brand-tagline").value=b.tagline || "";
  $("brand-logo").value=b.logo || "";
  $("brand-favicon").value=b.favicon || "";
  updatePreview();
}
async function refresh() {
  const response = await api(isStudio ? "/api/admin/themes" : "/api/themes");
  ui.themes=response.themes || []; ui.selected=response.selected || {}; ui.nft=response.nft || {};
  render();
}
function initStudio(){
  $("studio-controls").hidden=false;
  $("app").addEventListener("change",updateSelection);
  ["theme-key","brand-name","brand-tagline","brand-logo","brand-favicon"].forEach(k=>{
    $(k).addEventListener("input",updatePreview); $(k).addEventListener("change",updatePreview);
  });
  $("selection-form").addEventListener("submit",async event=>{
    event.preventDefault();
    const payload={action:"select",app:$("app").value,theme_key:$("theme-key").value,
      token_id:Number($("nft-token").value||0),branding:{name:$("brand-name").value,
        tagline:$("brand-tagline").value,logo:$("brand-logo").value,favicon:$("brand-favicon").value}};
    try {await api("/api/admin/themes",{body:payload});setMessage("Theme selected. Refresh the app to see your branding.");await refresh();}
    catch(e){setMessage(e.message,true);}
  });
  $("publish-form").addEventListener("submit",async event=>{
    event.preventDefault();try{const manifest=JSON.parse($("manifest").value);
      const res=await api("/api/admin/themes",{body:{action:"publish",manifest}});
      setMessage(`Published ${res.key} on IPFS: ${res.cid}`);await refresh();
    }catch(e){setMessage(e.message,true);}
  });
  $("import-form").addEventListener("submit",async event=>{
    event.preventDefault();try {const res=await api("/api/admin/themes",{body:{action:"import",cid:$("import-cid").value.trim()}});
      setMessage(`Verified and imported ${res.key}`);await refresh();
    }catch(e){setMessage(e.message,true);}
  });
  $("manifest").value=JSON.stringify({schema:"damage-theme/v1",id:"my-theme",version:"1.0.0",
    name:"My Theme",description:"A portable, branded theme",
    tokens:{background:"#111b2a",surface:"#1c2b40",text:"#f2f5ff",muted:"#a4b8d1",accent:"#a5d77d",border:"#394c63"},
    branding:{name:"",tagline:"",logo:"",favicon:""},
    apps:apps,price_sats:2500,price_damage:500000000},null,2);
}
if (!isStudio) { $("admin-link").hidden=true; }
else initStudio();
$("refresh").addEventListener("click",()=>refresh().catch(e=>setMessage(e.message,true)));
refresh().catch(e=>setMessage(e.message,true));
