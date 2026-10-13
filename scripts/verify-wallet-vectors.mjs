// Offline independent cross-check of PUBLIC TEST FIXTURES ONLY.
// No npm dependencies; never pass a real recovery phrase to this script.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash, createHmac, pbkdf2Sync, createPrivateKey, createPublicKey } from 'node:crypto';

const fixtures = JSON.parse(readFileSync(new URL('../apps/damage/test/fixtures/wallet_vectors.json', import.meta.url)));
const wordBytes = readFileSync(new URL('../apps/damage/priv/bip39/english.txt', import.meta.url));
const sha256 = (b) => createHash('sha256').update(b).digest();
assert.equal(sha256(wordBytes).toString('hex'), '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda');
const words = wordBytes.toString('utf8').trimEnd().split('\n');
assert.equal(words.length, 2048);
const indices = new Map(words.map((w, i) => [w, i]));

function validateMnemonic(mnemonic) {
  const chunks = mnemonic.split(' ');
  assert.ok([12, 15, 18, 21, 24].includes(chunks.length));
  const bits = chunks.map((word) => {
    assert.ok(indices.has(word));
    return indices.get(word).toString(2).padStart(11, '0');
  }).join('');
  const cs = chunks.length / 3;
  const entropyBits = bits.slice(0, -cs);
  const entropy = Buffer.from(entropyBits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const hashBits = [...sha256(entropy)].map((b) => b.toString(2).padStart(8, '0')).join('');
  assert.equal(bits.slice(-cs), hashBits.slice(0, cs));
  return entropy;
}

function derive(seed, path) {
  let digest = createHmac('sha512', 'ed25519 seed').update(seed).digest();
  for (const index of path) {
    const data = Buffer.alloc(37);
    digest.copy(data, 1, 0, 32);
    data.writeUInt32BE(index + 0x80000000, 33);
    digest = createHmac('sha512', digest.subarray(32)).update(data).digest();
  }
  return digest.subarray(0, 32);
}

function base58(data) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let n = BigInt(`0x${data.toString('hex')}`);
  let result = '';
  while (n > 0n) { result = alphabet[Number(n % 58n)] + result; n /= 58n; }
  for (const b of data) { if (b !== 0) break; result = `1${result}`; }
  return result;
}

const publishedSeed = pbkdf2Sync(fixtures[0].mnemonic, 'mnemonicTREZOR', 2048, 64, 'sha512');
assert.equal(publishedSeed.toString('hex'), 'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04');
assert.equal(derive(Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex'), [0, 1, 2, 2, 1000000000]).toString('hex'), '8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793');
for (const f of fixtures) {
  assert.equal(validateMnemonic(f.mnemonic).toString('hex'), f.entropy_hex);
  const seed = pbkdf2Sync(f.mnemonic.normalize('NFKD'), 'mnemonic', 2048, 64, 'sha512');
  assert.equal(seed.toString('hex'), f.bip39_seed_hex);
  const key = derive(seed, [44, 457, 0, 0, 0]);
  assert.equal(key.toString('hex'), f.signing_seed_hex);
  const privateKey = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), key]),
    format: 'der', type: 'pkcs8',
  });
  const pub = createPublicKey(privateKey).export({format: 'der', type: 'spki'}).subarray(-32);
  assert.equal(pub.toString('hex'), f.public_key_hex);
  const address = `ak_${base58(Buffer.concat([pub, sha256(sha256(pub)).subarray(0, 4)]))}`;
  assert.equal(address, f.address);
  console.log(`Verified ${f.mnemonic.split(' ').length}-word PUBLIC TEST FIXTURE: ${address}`);
}
console.log('Wordlist, published BIP-39/SLIP-0010 checks, and all four AEX-10 fixtures passed.');
