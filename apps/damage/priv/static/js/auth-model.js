/* Pure helpers shared by the auth UI and regression tests. No wallet side effects.
 * Address checks here are syntax checks only. Leading zero bytes can produce
 * shorter Base58 encodings; checksum/key validity is verified by the server. */
export function normaliseSession(data) {
  if (!data || data.authenticated !== true || !['wallet', 'custodial'].includes(data.mode) ||
      !/^ak_[1-9A-HJ-NP-Za-km-z]{32,64}$/.test(data.address || '') ||
      !/^ds1\.[0-9a-f]{64}$/.test(data.access_token || '') ||
      !Number.isSafeInteger(data.expires_at) || data.expires_at <= Date.now() / 1000 ||
      !data.capabilities || typeof data.capabilities !== 'object') {
    throw new Error('The server did not return a valid browser session.');
  }
  return Object.freeze({...data, capabilities: Object.freeze({...data.capabilities})});
}
export function signatureHex(response) {
  if (response?.ok === false) throw new Error('The wallet declined the signature request.');
  const signature = typeof response === 'string' ? response : response?.result?.signature ?? response?.signature;
  if (typeof signature !== 'string' || !/^[0-9a-fA-F]{128}$/.test(signature)) {
    throw new Error('The wallet did not return a supported message signature.');
  }
  return signature.toLowerCase();
}
export function errorMessage(body, status) {
  if (status === 429) return 'Too many attempts. Wait a minute and try again.';
  if (typeof body?.message === 'string') return body.message.slice(0, 500);
  return status >= 500 ? 'The service is unavailable. Please try again.' : `The request failed (HTTP ${status}).`;
}
export function nonce() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
}
export function callbackURL(origin, state, phase, cancel = false) {
  const url = new URL('/', origin);
  // Fragments never enter HTTP access logs or the HTTP Referer header.
  const p = new URLSearchParams({state, phase, result: cancel ? 'cancel' : 'ok'});
  if (!cancel) {
    p.set('address', '{address}');
    p.set(phase === 'connect' ? 'networkId' : 'signature', phase === 'connect' ? '{networkId}' : '{signature}');
  }
  // Preserve wallet template placeholders through outer URL parameter encoding.
  url.hash = 'wallet-callback?' + p.toString().replace(/%7B/g, '{').replace(/%7D/g, '}');
  return url.toString();
}
export function walletDeepLink(phase, origin, state, message) {
  if (!['connect', 'sign'].includes(phase)) throw new Error('Unsupported wallet operation.');
  const url = new URL(phase === 'connect' ? '/address' : '/sign-message', 'https://wallet.superhero.com');
  url.searchParams.set('x-success', callbackURL(origin, state, phase));
  url.searchParams.set('x-cancel', callbackURL(origin, state, phase, true));
  if (phase === 'sign') {
    if (typeof message !== 'string' || !message) throw new Error('A sign-in challenge is required.');
    url.searchParams.set('message', message); // Plain UTF-8; do not label it hex.
  }
  return url.toString();
}
export function parseCallback(hash, pending, now = Date.now()) {
  if (!hash.startsWith('#wallet-callback?')) return null;
  const p = new URLSearchParams(hash.slice('#wallet-callback?'.length));
  for (const key of p.keys()) if (p.getAll(key).length !== 1) throw new Error('Invalid wallet callback.');
  if (!pending || typeof pending.state !== 'string' || !/^[0-9a-f]{64}$/.test(pending.state) ||
      p.get('state') !== pending.state || p.get('phase') !== pending.phase ||
      !Number.isFinite(pending.createdAt) || now - pending.createdAt > 600000 || now < pending.createdAt) {
    throw new Error('This wallet return is stale or belongs to another browser tab. Start again.');
  }
  if (p.get('result') === 'cancel') return {cancelled: true};
  if (p.get('result') !== 'ok') throw new Error('Invalid wallet callback.');
  const address = p.get('address');
  if (!/^ak_[1-9A-HJ-NP-Za-km-z]{32,64}$/.test(address || '')) throw new Error('The wallet did not return an account.');
  if (pending.phase === 'sign') {
    if (address !== pending.challenge?.address) throw new Error('The wallet account changed. Connect again.');
    return {address, signature: signatureHex(p.get('signature')), challenge: pending.challenge};
  }
  return {address, networkId: p.get('networkId')};
}
