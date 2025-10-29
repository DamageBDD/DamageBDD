// crypto.js
// Small crypto helper module that integrates with a "wallet" object.
// Exports: createCryptoModule(wallet) -> { signMessage, verifyMessage, encryptFor, decryptMessage, getPublicKey }

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function toBase64Url(buff) {
  return Buffer.from(buff).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function fromBase64Url(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return Buffer.from(s, 'base64');
}

async function subtle() {
  if (typeof window !== 'undefined' && window.crypto && window.crypto.subtle) return window.crypto.subtle;
  if (typeof globalThis !== 'undefined' && globalThis.crypto && globalThis.crypto.subtle) return globalThis.crypto.subtle;
  // Node.js: globalThis.crypto.subtle available on modern Node; otherwise require('crypto').webcrypto.subtle not allowed in browser
  if (typeof require === 'function') {
    try {
      const { webcrypto } = require('crypto');
      return webcrypto.subtle;
    } catch (e) {
      throw new Error('No SubtleCrypto available in this environment.');
    }
  }
  throw new Error('No SubtleCrypto available in this environment.');
}

async function sha256(data) {
  const s = await subtle();
  const hash = await s.digest('SHA-256', data instanceof Uint8Array ? data : encoder.encode(data));
  return new Uint8Array(hash);
}

/**
 * Create a crypto module bound to a wallet interface.
 * Wallet recommended methods (if available):
 *  - wallet.signMessage(message: string|Uint8Array) -> Promise<signatureBytes|base64>
 *  - wallet.verifyMessage(message, signature, publicKey) -> Promise<boolean>
 *  - wallet.encrypt(recipientPublicKey, message) -> Promise<encryptedPayloadObject>
 *  - wallet.decrypt(encryptedPayloadObject) -> Promise<plaintext>
 *  - wallet.getPublicKey() -> Promise<Uint8Array|base64|PEM>
 *
 * Fallbacks:
 *  - If wallet does not expose encrypt/decrypt, module will do ephemeral ECDH with P-256 + HKDF + AES-GCM
 *  - If wallet does not expose signMessage, module will attempt local ECDSA if wallet exposes private key (dangerous)
 */
export function createCryptoModule(wallet) {
  if (!wallet) throw new Error('wallet is required');

  // Helpers: import/export ECDH/ECDSA keys (P-256)
  async function importEcdhPublicKeyRaw(rawBytes) {
    const s = await subtle();
    return s.importKey('raw', rawBytes, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  }
  async function importEcdsaPublicKeySpki(spkiBytes) {
    const s = await subtle();
    return s.importKey('spki', spkiBytes, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify']);
  }
  async function importAesKey(raw) {
    const s = await subtle();
    return s.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
  }

  // HKDF (uses WebCrypto subtle)
  async function hkdf(ikm, salt, info, length = 32) {
    const s = await subtle();
    const key = await s.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
    const derived = await s.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: salt || new Uint8Array([]), info: info || new Uint8Array([]) }, key, length * 8);
    return new Uint8Array(derived);
  }

  // Convert variety of public key encodings to raw Uint8Array expected by WebCrypto 'raw' import
  function normalizePublicKeyInput(pub) {
    if (!pub) throw new Error('public key required');
    if (pub instanceof Uint8Array || Buffer.isBuffer(pub)) return new Uint8Array(pub);
    if (typeof pub === 'string') {
      // detect base64 or base64url or hex or PEM
      if (pub.startsWith('-----BEGIN')) {
        // PEM -> strip headers
        const body = pub.replace(/-----.*?-----/g, '').replace(/\s+/g, '');
        return new Uint8Array(Buffer.from(body, 'base64'));
      }
      // base64 url?
      try {
        // try base64url decode
        return new Uint8Array(fromBase64Url(pub));
      } catch (e) {
        // maybe hex
        if (/^[0-9a-fA-F]+$/.test(pub)) {
          const b = Buffer.from(pub, 'hex');
          return new Uint8Array(b);
        }
      }
    }
    throw new Error('Unsupported public key format');
  }

  // ---------- Signing ----------
  async function signMessage(message) {
    // Accept string or Uint8Array
    const data = message instanceof Uint8Array ? message : encoder.encode(String(message));

    // Preferred: wallet.signMessage
    if (typeof wallet.signMessage === 'function') {
      const sig = await wallet.signMessage(data);
      // Normalize: if wallet returned base64 string, convert to Uint8Array
      if (typeof sig === 'string') return fromBase64Url(sig) || Buffer.from(sig, 'base64');
      if (sig instanceof Uint8Array || Buffer.isBuffer(sig)) return new Uint8Array(sig);
      return sig;
    }

    // Fallback: wallet.exportPrivateKey -> local ECDSA sign (dangerous, only for trusted wallet)
    if (typeof wallet.exportPrivateKey === 'function') {
      const priv = await wallet.exportPrivateKey(); // expected Uint8Array / PEM / base64
      const privRaw = normalizePublicKeyInput(priv); // this will throw if format bad
      const s = await subtle();
      // Import as PKCS8 (assume wallet gave PKCS8 if PEM) - try multiple import methods
      let key;
      try {
        key = await s.importKey('pkcs8', privRaw, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
      } catch (e) {
        throw new Error('Cannot import private key for fallback signing. Provide wallet.signMessage or allow private key export in PKCS8 format.');
      }
      const signature = await s.sign({ name: 'ECDSA', hash: { name: 'SHA-256' } }, key, data);
      return new Uint8Array(signature);
    }

    throw new Error('Wallet does not support signMessage and private key export not available. Provide wallet.signMessage.');
  }

  async function verifyMessage(message, signature, publicKey) {
    const data = message instanceof Uint8Array ? message : encoder.encode(String(message));
    const sigBuf = signature instanceof Uint8Array || Buffer.isBuffer(signature) ? new Uint8Array(signature) : fromBase64Url(String(signature));

    if (typeof wallet.verifyMessage === 'function') {
      return wallet.verifyMessage(data, sigBuf, publicKey);
    }

    // Fallback: WebCrypto verify using provided publicKey (SPKI or raw)
    const pubRaw = normalizePublicKeyInput(publicKey);
    // If SPKI (likely) try SPKI import; if raw length matches uncompressed EC point (65 bytes for P-256) use 'raw' import and convert to spki may be impossible; prefer SPKI
    try {
      const s = await subtle();
      let key;
      // if looks like SPKI DER (starts with 0x30)
      if (pubRaw[0] === 0x30) {
        key = await importEcdsaPublicKeySpki(pubRaw.buffer || pubRaw);
      } else {
        // attempt to convert raw EC uncompressed key to SPKI: many libs don't provide easy convert; try import raw as "raw" with ECDSA (not supported by many platforms)
        key = await s.importKey('raw', pubRaw.buffer || pubRaw, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify']);
      }
      const ok = await s.verify({ name: 'ECDSA', hash: { name: 'SHA-256' } }, key, sigBuf, data);
      return ok;
    } catch (e) {
      throw new Error('Cannot verify message: ' + e.message);
    }
  }

  // ---------- Encryption: ECDH ephemeral + AES-GCM fallback ----------
  // encrypted payload format returned by encryptFor when using fallback:
  // { ephemPublic: base64url, iv: base64url, ciphertext: base64url, tag: base64url (if separate) }
  async function encryptFor(recipientPublicKey, message) {
    const data = message instanceof Uint8Array ? message : encoder.encode(String(message));

    if (typeof wallet.encrypt === 'function') {
      return wallet.encrypt(recipientPublicKey, data);
    }

    // Fallback: ephemeral ECDH (P-256) -> HKDF -> AES-GCM
    const s = await subtle();
    const recRaw = normalizePublicKeyInput(recipientPublicKey);
    const recKey = await importEcdhPublicKeyRaw(recRaw.buffer || recRaw);

    // generate ephemeral key
    const eph = await s.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const ephPubRaw = await s.exportKey('raw', eph.publicKey); // uncompressed point 65 bytes

    const shared = await s.deriveBits({ name: 'ECDH', public: recKey }, eph.privateKey, 256);
    const hk = await hkdf(new Uint8Array(shared), null, encoder.encode('ecdh-aes-gcm'), 32);

    // AES-GCM key
    const aesKey = await importAesKey(hk.buffer || hk);

    const iv = cryptoGetRandomBytes(12);
    const ct = await s.encrypt({ name: 'AES-GCM', iv: iv }, aesKey, data);

    return {
      kind: 'ecdh-aes-gcm',
      ephemPublic: toBase64Url(new Uint8Array(ephPubRaw)),
      iv: toBase64Url(iv),
      ciphertext: toBase64Url(new Uint8Array(ct)),
    };
  }

  async function decryptMessage(payload) {
    // If wallet provides decrypt, use it.
    if (typeof wallet.decrypt === 'function') {
      return wallet.decrypt(payload);
    }

    // Fallback expects payload produced by encryptFor (ephemeral ECDH)
    if (!payload || payload.kind !== 'ecdh-aes-gcm') throw new Error('Unsupported payload format for fallback decrypt.');

    // Need wallet private key or decrypt helper
    // Try wallet.getPrivateKey or wallet.exportPrivateKey
    if (typeof wallet.getPrivateKey !== 'function' && typeof wallet.exportPrivateKey !== 'function') {
      throw new Error('Wallet must provide decrypt or expose private key (getPrivateKey/exportPrivateKey) for fallback decrypt.');
    }

    const priv = typeof wallet.getPrivateKey === 'function' ? await wallet.getPrivateKey() : await wallet.exportPrivateKey();
    const privRaw = normalizePublicKeyInput(priv);

    const s = await subtle();
    // import private as PKCS8
    let privKey;
    try {
      privKey = await s.importKey('pkcs8', privRaw, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    } catch (e) {
      throw new Error('Cannot import private key (expect PKCS8 DER/PEM) for fallback decrypt.');
    }

    // import ephemeral public
    const ephRaw = fromBase64Url(payload.ephemPublic);
    const ephPub = await importEcdhPublicKeyRaw(ephRaw.buffer || ephRaw);

    const shared = await s.deriveBits({ name: 'ECDH', public: ephPub }, privKey, 256);
    const hk = await hkdf(new Uint8Array(shared), null, encoder.encode('ecdh-aes-gcm'), 32);
    const aesKey = await importAesKey(hk.buffer || hk);

    const iv = fromBase64Url(payload.iv);
    const ct = fromBase64Url(payload.ciphertext);

    const plainBuf = await s.decrypt({ name: 'AES-GCM', iv: new Uint8Array(iv) }, aesKey, ct);
    return new Uint8Array(plainBuf);
  }

  async function getPublicKey() {
    if (typeof wallet.getPublicKey === 'function') return wallet.getPublicKey();
    if (typeof wallet.exportPublicKey === 'function') return wallet.exportPublicKey();
    throw new Error('wallet must provide getPublicKey() or exportPublicKey()');
  }

  return {
    signMessage,
    verifyMessage,
    encryptFor,
    decryptMessage,
    getPublicKey,
  };
}

// Utility: cryptographically secure random bytes
function cryptoGetRandomBytes(n) {
  if (typeof window !== 'undefined' && window.crypto && window.crypto.getRandomValues) {
    const b = new Uint8Array(n);
    window.crypto.getRandomValues(b);
    return b;
  }
  if (typeof require === 'function') {
    try {
      const { randomBytes } = require('crypto');
      return new Uint8Array(randomBytes(n));
    } catch (e) {
      throw new Error('No secure random available');
    }
  }
  throw new Error('No secure random available');
}
