export const escapeHTML = v => String(v ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function validPubkey(v){return typeof v==='string'&&/^[0-9a-f]{64}$/.test(v);}
export function relayUrls(urls){if(!urls.length||urls.length>5)throw Error('Use between one and five relay URLs.');return [...new Set(urls.map(s=>{const u=new URL(s);if(u.protocol!=='wss:'||u.username||u.password)throw Error('Relay connections must use wss:// without credentials.');return u.href;}))];}
