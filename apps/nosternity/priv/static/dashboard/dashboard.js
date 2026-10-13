// src/core.js
var escapeHTML = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
function validPubkey(v) {
  return typeof v === "string" && /^[0-9a-f]{64}$/.test(v);
}
function relayUrls(urls) {
  if (!urls.length || urls.length > 5) throw Error("Use between one and five relay URLs.");
  return [...new Set(urls.map((s) => {
    const u = new URL(s);
    if (u.protocol !== "wss:" || u.username || u.password) throw Error("Relay connections must use wss:// without credentials.");
    return u.href;
  }))];
}

// node_modules/@noble/hashes/utils.js
function isBytes(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array";
}
function anumber(n, title = "") {
  if (!Number.isSafeInteger(n) || n < 0) {
    const prefix = title && `"${title}" `;
    throw new Error(`${prefix}expected integer >= 0, got ${n}`);
  }
}
function abytes(value, length, title = "") {
  const bytes = isBytes(value);
  const len = value?.length;
  const needsLen = length !== void 0;
  if (!bytes || needsLen && len !== length) {
    const prefix = title && `"${title}" `;
    const ofLen = needsLen ? ` of length ${length}` : "";
    const got = bytes ? `length=${len}` : `type=${typeof value}`;
    throw new Error(prefix + "expected Uint8Array" + ofLen + ", got " + got);
  }
  return value;
}
function ahash(h) {
  if (typeof h !== "function" || typeof h.create !== "function")
    throw new Error("Hash must wrapped by utils.createHasher");
  anumber(h.outputLen);
  anumber(h.blockLen);
}
function aexists(instance, checkFinished = true) {
  if (instance.destroyed)
    throw new Error("Hash instance has been destroyed");
  if (checkFinished && instance.finished)
    throw new Error("Hash#digest() has already been called");
}
function aoutput(out, instance) {
  abytes(out, void 0, "digestInto() output");
  const min = instance.outputLen;
  if (out.length < min) {
    throw new Error('"digestInto() output" expected to be of length >=' + min);
  }
}
function clean(...arrays) {
  for (let i4 = 0; i4 < arrays.length; i4++) {
    arrays[i4].fill(0);
  }
}
function createView(arr) {
  return new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
}
function rotr(word, shift) {
  return word << 32 - shift | word >>> shift;
}
var hasHexBuiltin = /* @__PURE__ */ (() => (
  // @ts-ignore
  typeof Uint8Array.from([]).toHex === "function" && typeof Uint8Array.fromHex === "function"
))();
var hexes = /* @__PURE__ */ Array.from({ length: 256 }, (_, i4) => i4.toString(16).padStart(2, "0"));
function bytesToHex(bytes) {
  abytes(bytes);
  if (hasHexBuiltin)
    return bytes.toHex();
  let hex = "";
  for (let i4 = 0; i4 < bytes.length; i4++) {
    hex += hexes[bytes[i4]];
  }
  return hex;
}
var asciis = { _0: 48, _9: 57, A: 65, F: 70, a: 97, f: 102 };
function asciiToBase16(ch) {
  if (ch >= asciis._0 && ch <= asciis._9)
    return ch - asciis._0;
  if (ch >= asciis.A && ch <= asciis.F)
    return ch - (asciis.A - 10);
  if (ch >= asciis.a && ch <= asciis.f)
    return ch - (asciis.a - 10);
  return;
}
function hexToBytes(hex) {
  if (typeof hex !== "string")
    throw new Error("hex string expected, got " + typeof hex);
  if (hasHexBuiltin)
    return Uint8Array.fromHex(hex);
  const hl = hex.length;
  const al = hl / 2;
  if (hl % 2)
    throw new Error("hex string expected, got unpadded hex of length " + hl);
  const array = new Uint8Array(al);
  for (let ai = 0, hi = 0; ai < al; ai++, hi += 2) {
    const n1 = asciiToBase16(hex.charCodeAt(hi));
    const n2 = asciiToBase16(hex.charCodeAt(hi + 1));
    if (n1 === void 0 || n2 === void 0) {
      const char = hex[hi] + hex[hi + 1];
      throw new Error('hex string expected, got non-hex character "' + char + '" at index ' + hi);
    }
    array[ai] = n1 * 16 + n2;
  }
  return array;
}
function concatBytes(...arrays) {
  let sum = 0;
  for (let i4 = 0; i4 < arrays.length; i4++) {
    const a = arrays[i4];
    abytes(a);
    sum += a.length;
  }
  const res = new Uint8Array(sum);
  for (let i4 = 0, pad3 = 0; i4 < arrays.length; i4++) {
    const a = arrays[i4];
    res.set(a, pad3);
    pad3 += a.length;
  }
  return res;
}
function createHasher(hashCons, info = {}) {
  const hashC = (msg, opts) => hashCons(opts).update(msg).digest();
  const tmp = hashCons(void 0);
  hashC.outputLen = tmp.outputLen;
  hashC.blockLen = tmp.blockLen;
  hashC.create = (opts) => hashCons(opts);
  Object.assign(hashC, info);
  return Object.freeze(hashC);
}
function randomBytes(bytesLength = 32) {
  const cr = typeof globalThis === "object" ? globalThis.crypto : null;
  if (typeof cr?.getRandomValues !== "function")
    throw new Error("crypto.getRandomValues must be defined");
  return cr.getRandomValues(new Uint8Array(bytesLength));
}
var oidNist = (suffix) => ({
  oid: Uint8Array.from([6, 9, 96, 134, 72, 1, 101, 3, 4, 2, suffix])
});

// node_modules/@noble/hashes/_md.js
function Chi(a, b, c) {
  return a & b ^ ~a & c;
}
function Maj(a, b, c) {
  return a & b ^ a & c ^ b & c;
}
var HashMD = class {
  blockLen;
  outputLen;
  padOffset;
  isLE;
  // For partial updates less than block size
  buffer;
  view;
  finished = false;
  length = 0;
  pos = 0;
  destroyed = false;
  constructor(blockLen, outputLen, padOffset, isLE2) {
    this.blockLen = blockLen;
    this.outputLen = outputLen;
    this.padOffset = padOffset;
    this.isLE = isLE2;
    this.buffer = new Uint8Array(blockLen);
    this.view = createView(this.buffer);
  }
  update(data) {
    aexists(this);
    abytes(data);
    const { view, buffer, blockLen } = this;
    const len = data.length;
    for (let pos = 0; pos < len; ) {
      const take = Math.min(blockLen - this.pos, len - pos);
      if (take === blockLen) {
        const dataView = createView(data);
        for (; blockLen <= len - pos; pos += blockLen)
          this.process(dataView, pos);
        continue;
      }
      buffer.set(data.subarray(pos, pos + take), this.pos);
      this.pos += take;
      pos += take;
      if (this.pos === blockLen) {
        this.process(view, 0);
        this.pos = 0;
      }
    }
    this.length += data.length;
    this.roundClean();
    return this;
  }
  digestInto(out) {
    aexists(this);
    aoutput(out, this);
    this.finished = true;
    const { buffer, view, blockLen, isLE: isLE2 } = this;
    let { pos } = this;
    buffer[pos++] = 128;
    clean(this.buffer.subarray(pos));
    if (this.padOffset > blockLen - pos) {
      this.process(view, 0);
      pos = 0;
    }
    for (let i4 = pos; i4 < blockLen; i4++)
      buffer[i4] = 0;
    view.setBigUint64(blockLen - 8, BigInt(this.length * 8), isLE2);
    this.process(view, 0);
    const oview = createView(out);
    const len = this.outputLen;
    if (len % 4)
      throw new Error("_sha2: outputLen must be aligned to 32bit");
    const outLen = len / 4;
    const state2 = this.get();
    if (outLen > state2.length)
      throw new Error("_sha2: outputLen bigger than state");
    for (let i4 = 0; i4 < outLen; i4++)
      oview.setUint32(4 * i4, state2[i4], isLE2);
  }
  digest() {
    const { buffer, outputLen } = this;
    this.digestInto(buffer);
    const res = buffer.slice(0, outputLen);
    this.destroy();
    return res;
  }
  _cloneInto(to) {
    to ||= new this.constructor();
    to.set(...this.get());
    const { blockLen, buffer, length, finished, destroyed, pos } = this;
    to.destroyed = destroyed;
    to.finished = finished;
    to.length = length;
    to.pos = pos;
    if (length % blockLen)
      to.buffer.set(buffer);
    return to;
  }
  clone() {
    return this._cloneInto();
  }
};
var SHA256_IV = /* @__PURE__ */ Uint32Array.from([
  1779033703,
  3144134277,
  1013904242,
  2773480762,
  1359893119,
  2600822924,
  528734635,
  1541459225
]);

// node_modules/@noble/hashes/sha2.js
var SHA256_K = /* @__PURE__ */ Uint32Array.from([
  1116352408,
  1899447441,
  3049323471,
  3921009573,
  961987163,
  1508970993,
  2453635748,
  2870763221,
  3624381080,
  310598401,
  607225278,
  1426881987,
  1925078388,
  2162078206,
  2614888103,
  3248222580,
  3835390401,
  4022224774,
  264347078,
  604807628,
  770255983,
  1249150122,
  1555081692,
  1996064986,
  2554220882,
  2821834349,
  2952996808,
  3210313671,
  3336571891,
  3584528711,
  113926993,
  338241895,
  666307205,
  773529912,
  1294757372,
  1396182291,
  1695183700,
  1986661051,
  2177026350,
  2456956037,
  2730485921,
  2820302411,
  3259730800,
  3345764771,
  3516065817,
  3600352804,
  4094571909,
  275423344,
  430227734,
  506948616,
  659060556,
  883997877,
  958139571,
  1322822218,
  1537002063,
  1747873779,
  1955562222,
  2024104815,
  2227730452,
  2361852424,
  2428436474,
  2756734187,
  3204031479,
  3329325298
]);
var SHA256_W = /* @__PURE__ */ new Uint32Array(64);
var SHA2_32B = class extends HashMD {
  constructor(outputLen) {
    super(64, outputLen, 8, false);
  }
  get() {
    const { A, B, C, D, E, F, G, H } = this;
    return [A, B, C, D, E, F, G, H];
  }
  // prettier-ignore
  set(A, B, C, D, E, F, G, H) {
    this.A = A | 0;
    this.B = B | 0;
    this.C = C | 0;
    this.D = D | 0;
    this.E = E | 0;
    this.F = F | 0;
    this.G = G | 0;
    this.H = H | 0;
  }
  process(view, offset) {
    for (let i4 = 0; i4 < 16; i4++, offset += 4)
      SHA256_W[i4] = view.getUint32(offset, false);
    for (let i4 = 16; i4 < 64; i4++) {
      const W15 = SHA256_W[i4 - 15];
      const W2 = SHA256_W[i4 - 2];
      const s0 = rotr(W15, 7) ^ rotr(W15, 18) ^ W15 >>> 3;
      const s1 = rotr(W2, 17) ^ rotr(W2, 19) ^ W2 >>> 10;
      SHA256_W[i4] = s1 + SHA256_W[i4 - 7] + s0 + SHA256_W[i4 - 16] | 0;
    }
    let { A, B, C, D, E, F, G, H } = this;
    for (let i4 = 0; i4 < 64; i4++) {
      const sigma1 = rotr(E, 6) ^ rotr(E, 11) ^ rotr(E, 25);
      const T1 = H + sigma1 + Chi(E, F, G) + SHA256_K[i4] + SHA256_W[i4] | 0;
      const sigma0 = rotr(A, 2) ^ rotr(A, 13) ^ rotr(A, 22);
      const T2 = sigma0 + Maj(A, B, C) | 0;
      H = G;
      G = F;
      F = E;
      E = D + T1 | 0;
      D = C;
      C = B;
      B = A;
      A = T1 + T2 | 0;
    }
    A = A + this.A | 0;
    B = B + this.B | 0;
    C = C + this.C | 0;
    D = D + this.D | 0;
    E = E + this.E | 0;
    F = F + this.F | 0;
    G = G + this.G | 0;
    H = H + this.H | 0;
    this.set(A, B, C, D, E, F, G, H);
  }
  roundClean() {
    clean(SHA256_W);
  }
  destroy() {
    this.set(0, 0, 0, 0, 0, 0, 0, 0);
    clean(this.buffer);
  }
};
var _SHA256 = class extends SHA2_32B {
  // We cannot use array here since array allows indexing by variable
  // which means optimizer/compiler cannot use registers.
  A = SHA256_IV[0] | 0;
  B = SHA256_IV[1] | 0;
  C = SHA256_IV[2] | 0;
  D = SHA256_IV[3] | 0;
  E = SHA256_IV[4] | 0;
  F = SHA256_IV[5] | 0;
  G = SHA256_IV[6] | 0;
  H = SHA256_IV[7] | 0;
  constructor() {
    super(32);
  }
};
var sha256 = /* @__PURE__ */ createHasher(
  () => new _SHA256(),
  /* @__PURE__ */ oidNist(1)
);

// node_modules/@noble/curves/utils.js
var _0n = /* @__PURE__ */ BigInt(0);
var _1n = /* @__PURE__ */ BigInt(1);
function abool(value, title = "") {
  if (typeof value !== "boolean") {
    const prefix = title && `"${title}" `;
    throw new Error(prefix + "expected boolean, got type=" + typeof value);
  }
  return value;
}
function abignumber(n) {
  if (typeof n === "bigint") {
    if (!isPosBig(n))
      throw new Error("positive bigint expected, got " + n);
  } else
    anumber(n);
  return n;
}
function numberToHexUnpadded(num2) {
  const hex = abignumber(num2).toString(16);
  return hex.length & 1 ? "0" + hex : hex;
}
function hexToNumber(hex) {
  if (typeof hex !== "string")
    throw new Error("hex string expected, got " + typeof hex);
  return hex === "" ? _0n : BigInt("0x" + hex);
}
function bytesToNumberBE(bytes) {
  return hexToNumber(bytesToHex(bytes));
}
function bytesToNumberLE(bytes) {
  return hexToNumber(bytesToHex(copyBytes(abytes(bytes)).reverse()));
}
function numberToBytesBE(n, len) {
  anumber(len);
  n = abignumber(n);
  const res = hexToBytes(n.toString(16).padStart(len * 2, "0"));
  if (res.length !== len)
    throw new Error("number too large");
  return res;
}
function numberToBytesLE(n, len) {
  return numberToBytesBE(n, len).reverse();
}
function copyBytes(bytes) {
  return Uint8Array.from(bytes);
}
function asciiToBytes(ascii) {
  return Uint8Array.from(ascii, (c, i4) => {
    const charCode = c.charCodeAt(0);
    if (c.length !== 1 || charCode > 127) {
      throw new Error(`string contains non-ASCII character "${ascii[i4]}" with code ${charCode} at position ${i4}`);
    }
    return charCode;
  });
}
var isPosBig = (n) => typeof n === "bigint" && _0n <= n;
function inRange(n, min, max) {
  return isPosBig(n) && isPosBig(min) && isPosBig(max) && min <= n && n < max;
}
function aInRange(title, n, min, max) {
  if (!inRange(n, min, max))
    throw new Error("expected valid " + title + ": " + min + " <= n < " + max + ", got " + n);
}
function bitLen(n) {
  let len;
  for (len = 0; n > _0n; n >>= _1n, len += 1)
    ;
  return len;
}
var bitMask = (n) => (_1n << BigInt(n)) - _1n;
function createHmacDrbg(hashLen, qByteLen, hmacFn) {
  anumber(hashLen, "hashLen");
  anumber(qByteLen, "qByteLen");
  if (typeof hmacFn !== "function")
    throw new Error("hmacFn must be a function");
  const u8n = (len) => new Uint8Array(len);
  const NULL = Uint8Array.of();
  const byte0 = Uint8Array.of(0);
  const byte1 = Uint8Array.of(1);
  const _maxDrbgIters = 1e3;
  let v = u8n(hashLen);
  let k = u8n(hashLen);
  let i4 = 0;
  const reset = () => {
    v.fill(1);
    k.fill(0);
    i4 = 0;
  };
  const h = (...msgs) => hmacFn(k, concatBytes(v, ...msgs));
  const reseed = (seed = NULL) => {
    k = h(byte0, seed);
    v = h();
    if (seed.length === 0)
      return;
    k = h(byte1, seed);
    v = h();
  };
  const gen = () => {
    if (i4++ >= _maxDrbgIters)
      throw new Error("drbg: tried max amount of iterations");
    let len = 0;
    const out = [];
    while (len < qByteLen) {
      v = h();
      const sl = v.slice();
      out.push(sl);
      len += v.length;
    }
    return concatBytes(...out);
  };
  const genUntil = (seed, pred) => {
    reset();
    reseed(seed);
    let res = void 0;
    while (!(res = pred(gen())))
      reseed();
    reset();
    return res;
  };
  return genUntil;
}
function validateObject(object, fields = {}, optFields = {}) {
  if (!object || typeof object !== "object")
    throw new Error("expected valid options object");
  function checkField(fieldName, expectedType, isOpt) {
    const val = object[fieldName];
    if (isOpt && val === void 0)
      return;
    const current = typeof val;
    if (current !== expectedType || val === null)
      throw new Error(`param "${fieldName}" is invalid: expected ${expectedType}, got ${current}`);
  }
  const iter = (f, isOpt) => Object.entries(f).forEach(([k, v]) => checkField(k, v, isOpt));
  iter(fields, false);
  iter(optFields, true);
}
function memoized(fn) {
  const map = /* @__PURE__ */ new WeakMap();
  return (arg, ...args) => {
    const val = map.get(arg);
    if (val !== void 0)
      return val;
    const computed = fn(arg, ...args);
    map.set(arg, computed);
    return computed;
  };
}

// node_modules/@noble/curves/abstract/modular.js
var _0n2 = /* @__PURE__ */ BigInt(0);
var _1n2 = /* @__PURE__ */ BigInt(1);
var _2n = /* @__PURE__ */ BigInt(2);
var _3n = /* @__PURE__ */ BigInt(3);
var _4n = /* @__PURE__ */ BigInt(4);
var _5n = /* @__PURE__ */ BigInt(5);
var _7n = /* @__PURE__ */ BigInt(7);
var _8n = /* @__PURE__ */ BigInt(8);
var _9n = /* @__PURE__ */ BigInt(9);
var _16n = /* @__PURE__ */ BigInt(16);
function mod(a, b) {
  const result = a % b;
  return result >= _0n2 ? result : b + result;
}
function pow2(x, power, modulo) {
  let res = x;
  while (power-- > _0n2) {
    res *= res;
    res %= modulo;
  }
  return res;
}
function invert(number, modulo) {
  if (number === _0n2)
    throw new Error("invert: expected non-zero number");
  if (modulo <= _0n2)
    throw new Error("invert: expected positive modulus, got " + modulo);
  let a = mod(number, modulo);
  let b = modulo;
  let x = _0n2, y = _1n2, u = _1n2, v = _0n2;
  while (a !== _0n2) {
    const q = b / a;
    const r = b % a;
    const m = x - u * q;
    const n = y - v * q;
    b = a, a = r, x = u, y = v, u = m, v = n;
  }
  const gcd2 = b;
  if (gcd2 !== _1n2)
    throw new Error("invert: does not exist");
  return mod(x, modulo);
}
function assertIsSquare(Fp, root, n) {
  if (!Fp.eql(Fp.sqr(root), n))
    throw new Error("Cannot find square root");
}
function sqrt3mod4(Fp, n) {
  const p1div4 = (Fp.ORDER + _1n2) / _4n;
  const root = Fp.pow(n, p1div4);
  assertIsSquare(Fp, root, n);
  return root;
}
function sqrt5mod8(Fp, n) {
  const p5div8 = (Fp.ORDER - _5n) / _8n;
  const n2 = Fp.mul(n, _2n);
  const v = Fp.pow(n2, p5div8);
  const nv = Fp.mul(n, v);
  const i4 = Fp.mul(Fp.mul(nv, _2n), v);
  const root = Fp.mul(nv, Fp.sub(i4, Fp.ONE));
  assertIsSquare(Fp, root, n);
  return root;
}
function sqrt9mod16(P) {
  const Fp_ = Field(P);
  const tn = tonelliShanks(P);
  const c1 = tn(Fp_, Fp_.neg(Fp_.ONE));
  const c2 = tn(Fp_, c1);
  const c3 = tn(Fp_, Fp_.neg(c1));
  const c4 = (P + _7n) / _16n;
  return (Fp, n) => {
    let tv1 = Fp.pow(n, c4);
    let tv2 = Fp.mul(tv1, c1);
    const tv3 = Fp.mul(tv1, c2);
    const tv4 = Fp.mul(tv1, c3);
    const e1 = Fp.eql(Fp.sqr(tv2), n);
    const e2 = Fp.eql(Fp.sqr(tv3), n);
    tv1 = Fp.cmov(tv1, tv2, e1);
    tv2 = Fp.cmov(tv4, tv3, e2);
    const e3 = Fp.eql(Fp.sqr(tv2), n);
    const root = Fp.cmov(tv1, tv2, e3);
    assertIsSquare(Fp, root, n);
    return root;
  };
}
function tonelliShanks(P) {
  if (P < _3n)
    throw new Error("sqrt is not defined for small field");
  let Q = P - _1n2;
  let S = 0;
  while (Q % _2n === _0n2) {
    Q /= _2n;
    S++;
  }
  let Z = _2n;
  const _Fp = Field(P);
  while (FpLegendre(_Fp, Z) === 1) {
    if (Z++ > 1e3)
      throw new Error("Cannot find square root: probably non-prime P");
  }
  if (S === 1)
    return sqrt3mod4;
  let cc = _Fp.pow(Z, Q);
  const Q1div2 = (Q + _1n2) / _2n;
  return function tonelliSlow(Fp, n) {
    if (Fp.is0(n))
      return n;
    if (FpLegendre(Fp, n) !== 1)
      throw new Error("Cannot find square root");
    let M3 = S;
    let c = Fp.mul(Fp.ONE, cc);
    let t = Fp.pow(n, Q);
    let R = Fp.pow(n, Q1div2);
    while (!Fp.eql(t, Fp.ONE)) {
      if (Fp.is0(t))
        return Fp.ZERO;
      let i4 = 1;
      let t_tmp = Fp.sqr(t);
      while (!Fp.eql(t_tmp, Fp.ONE)) {
        i4++;
        t_tmp = Fp.sqr(t_tmp);
        if (i4 === M3)
          throw new Error("Cannot find square root");
      }
      const exponent = _1n2 << BigInt(M3 - i4 - 1);
      const b = Fp.pow(c, exponent);
      M3 = i4;
      c = Fp.sqr(b);
      t = Fp.mul(t, c);
      R = Fp.mul(R, b);
    }
    return R;
  };
}
function FpSqrt(P) {
  if (P % _4n === _3n)
    return sqrt3mod4;
  if (P % _8n === _5n)
    return sqrt5mod8;
  if (P % _16n === _9n)
    return sqrt9mod16(P);
  return tonelliShanks(P);
}
var FIELD_FIELDS = [
  "create",
  "isValid",
  "is0",
  "neg",
  "inv",
  "sqrt",
  "sqr",
  "eql",
  "add",
  "sub",
  "mul",
  "pow",
  "div",
  "addN",
  "subN",
  "mulN",
  "sqrN"
];
function validateField(field) {
  const initial = {
    ORDER: "bigint",
    BYTES: "number",
    BITS: "number"
  };
  const opts = FIELD_FIELDS.reduce((map, val) => {
    map[val] = "function";
    return map;
  }, initial);
  validateObject(field, opts);
  return field;
}
function FpPow(Fp, num2, power) {
  if (power < _0n2)
    throw new Error("invalid exponent, negatives unsupported");
  if (power === _0n2)
    return Fp.ONE;
  if (power === _1n2)
    return num2;
  let p = Fp.ONE;
  let d = num2;
  while (power > _0n2) {
    if (power & _1n2)
      p = Fp.mul(p, d);
    d = Fp.sqr(d);
    power >>= _1n2;
  }
  return p;
}
function FpInvertBatch(Fp, nums, passZero = false) {
  const inverted = new Array(nums.length).fill(passZero ? Fp.ZERO : void 0);
  const multipliedAcc = nums.reduce((acc, num2, i4) => {
    if (Fp.is0(num2))
      return acc;
    inverted[i4] = acc;
    return Fp.mul(acc, num2);
  }, Fp.ONE);
  const invertedAcc = Fp.inv(multipliedAcc);
  nums.reduceRight((acc, num2, i4) => {
    if (Fp.is0(num2))
      return acc;
    inverted[i4] = Fp.mul(acc, inverted[i4]);
    return Fp.mul(acc, num2);
  }, invertedAcc);
  return inverted;
}
function FpLegendre(Fp, n) {
  const p1mod2 = (Fp.ORDER - _1n2) / _2n;
  const powered = Fp.pow(n, p1mod2);
  const yes = Fp.eql(powered, Fp.ONE);
  const zero = Fp.eql(powered, Fp.ZERO);
  const no = Fp.eql(powered, Fp.neg(Fp.ONE));
  if (!yes && !zero && !no)
    throw new Error("invalid Legendre symbol result");
  return yes ? 1 : zero ? 0 : -1;
}
function nLength(n, nBitLength) {
  if (nBitLength !== void 0)
    anumber(nBitLength);
  const _nBitLength = nBitLength !== void 0 ? nBitLength : n.toString(2).length;
  const nByteLength = Math.ceil(_nBitLength / 8);
  return { nBitLength: _nBitLength, nByteLength };
}
var _Field = class {
  ORDER;
  BITS;
  BYTES;
  isLE;
  ZERO = _0n2;
  ONE = _1n2;
  _lengths;
  _sqrt;
  // cached sqrt
  _mod;
  constructor(ORDER, opts = {}) {
    if (ORDER <= _0n2)
      throw new Error("invalid field: expected ORDER > 0, got " + ORDER);
    let _nbitLength = void 0;
    this.isLE = false;
    if (opts != null && typeof opts === "object") {
      if (typeof opts.BITS === "number")
        _nbitLength = opts.BITS;
      if (typeof opts.sqrt === "function")
        this.sqrt = opts.sqrt;
      if (typeof opts.isLE === "boolean")
        this.isLE = opts.isLE;
      if (opts.allowedLengths)
        this._lengths = opts.allowedLengths?.slice();
      if (typeof opts.modFromBytes === "boolean")
        this._mod = opts.modFromBytes;
    }
    const { nBitLength, nByteLength } = nLength(ORDER, _nbitLength);
    if (nByteLength > 2048)
      throw new Error("invalid field: expected ORDER of <= 2048 bytes");
    this.ORDER = ORDER;
    this.BITS = nBitLength;
    this.BYTES = nByteLength;
    this._sqrt = void 0;
    Object.preventExtensions(this);
  }
  create(num2) {
    return mod(num2, this.ORDER);
  }
  isValid(num2) {
    if (typeof num2 !== "bigint")
      throw new Error("invalid field element: expected bigint, got " + typeof num2);
    return _0n2 <= num2 && num2 < this.ORDER;
  }
  is0(num2) {
    return num2 === _0n2;
  }
  // is valid and invertible
  isValidNot0(num2) {
    return !this.is0(num2) && this.isValid(num2);
  }
  isOdd(num2) {
    return (num2 & _1n2) === _1n2;
  }
  neg(num2) {
    return mod(-num2, this.ORDER);
  }
  eql(lhs, rhs) {
    return lhs === rhs;
  }
  sqr(num2) {
    return mod(num2 * num2, this.ORDER);
  }
  add(lhs, rhs) {
    return mod(lhs + rhs, this.ORDER);
  }
  sub(lhs, rhs) {
    return mod(lhs - rhs, this.ORDER);
  }
  mul(lhs, rhs) {
    return mod(lhs * rhs, this.ORDER);
  }
  pow(num2, power) {
    return FpPow(this, num2, power);
  }
  div(lhs, rhs) {
    return mod(lhs * invert(rhs, this.ORDER), this.ORDER);
  }
  // Same as above, but doesn't normalize
  sqrN(num2) {
    return num2 * num2;
  }
  addN(lhs, rhs) {
    return lhs + rhs;
  }
  subN(lhs, rhs) {
    return lhs - rhs;
  }
  mulN(lhs, rhs) {
    return lhs * rhs;
  }
  inv(num2) {
    return invert(num2, this.ORDER);
  }
  sqrt(num2) {
    if (!this._sqrt)
      this._sqrt = FpSqrt(this.ORDER);
    return this._sqrt(this, num2);
  }
  toBytes(num2) {
    return this.isLE ? numberToBytesLE(num2, this.BYTES) : numberToBytesBE(num2, this.BYTES);
  }
  fromBytes(bytes, skipValidation = false) {
    abytes(bytes);
    const { _lengths: allowedLengths, BYTES, isLE: isLE2, ORDER, _mod: modFromBytes } = this;
    if (allowedLengths) {
      if (!allowedLengths.includes(bytes.length) || bytes.length > BYTES) {
        throw new Error("Field.fromBytes: expected " + allowedLengths + " bytes, got " + bytes.length);
      }
      const padded = new Uint8Array(BYTES);
      padded.set(bytes, isLE2 ? 0 : padded.length - bytes.length);
      bytes = padded;
    }
    if (bytes.length !== BYTES)
      throw new Error("Field.fromBytes: expected " + BYTES + " bytes, got " + bytes.length);
    let scalar = isLE2 ? bytesToNumberLE(bytes) : bytesToNumberBE(bytes);
    if (modFromBytes)
      scalar = mod(scalar, ORDER);
    if (!skipValidation) {
      if (!this.isValid(scalar))
        throw new Error("invalid field element: outside of range 0..ORDER");
    }
    return scalar;
  }
  // TODO: we don't need it here, move out to separate fn
  invertBatch(lst) {
    return FpInvertBatch(this, lst);
  }
  // We can't move this out because Fp6, Fp12 implement it
  // and it's unclear what to return in there.
  cmov(a, b, condition) {
    return condition ? b : a;
  }
};
function Field(ORDER, opts = {}) {
  return new _Field(ORDER, opts);
}
function getFieldBytesLength(fieldOrder) {
  if (typeof fieldOrder !== "bigint")
    throw new Error("field order must be bigint");
  const bitLength = fieldOrder.toString(2).length;
  return Math.ceil(bitLength / 8);
}
function getMinHashLength(fieldOrder) {
  const length = getFieldBytesLength(fieldOrder);
  return length + Math.ceil(length / 2);
}
function mapHashToField(key, fieldOrder, isLE2 = false) {
  abytes(key);
  const len = key.length;
  const fieldLen = getFieldBytesLength(fieldOrder);
  const minLen = getMinHashLength(fieldOrder);
  if (len < 16 || len < minLen || len > 1024)
    throw new Error("expected " + minLen + "-1024 bytes of input, got " + len);
  const num2 = isLE2 ? bytesToNumberLE(key) : bytesToNumberBE(key);
  const reduced = mod(num2, fieldOrder - _1n2) + _1n2;
  return isLE2 ? numberToBytesLE(reduced, fieldLen) : numberToBytesBE(reduced, fieldLen);
}

// node_modules/@noble/curves/abstract/curve.js
var _0n3 = /* @__PURE__ */ BigInt(0);
var _1n3 = /* @__PURE__ */ BigInt(1);
function negateCt(condition, item) {
  const neg = item.negate();
  return condition ? neg : item;
}
function normalizeZ(c, points) {
  const invertedZs = FpInvertBatch(c.Fp, points.map((p) => p.Z));
  return points.map((p, i4) => c.fromAffine(p.toAffine(invertedZs[i4])));
}
function validateW(W, bits) {
  if (!Number.isSafeInteger(W) || W <= 0 || W > bits)
    throw new Error("invalid window size, expected [1.." + bits + "], got W=" + W);
}
function calcWOpts(W, scalarBits) {
  validateW(W, scalarBits);
  const windows = Math.ceil(scalarBits / W) + 1;
  const windowSize = 2 ** (W - 1);
  const maxNumber = 2 ** W;
  const mask = bitMask(W);
  const shiftBy = BigInt(W);
  return { windows, windowSize, mask, maxNumber, shiftBy };
}
function calcOffsets(n, window2, wOpts) {
  const { windowSize, mask, maxNumber, shiftBy } = wOpts;
  let wbits = Number(n & mask);
  let nextN = n >> shiftBy;
  if (wbits > windowSize) {
    wbits -= maxNumber;
    nextN += _1n3;
  }
  const offsetStart = window2 * windowSize;
  const offset = offsetStart + Math.abs(wbits) - 1;
  const isZero = wbits === 0;
  const isNeg = wbits < 0;
  const isNegF = window2 % 2 !== 0;
  const offsetF = offsetStart;
  return { nextN, offset, isZero, isNeg, isNegF, offsetF };
}
var pointPrecomputes = /* @__PURE__ */ new WeakMap();
var pointWindowSizes = /* @__PURE__ */ new WeakMap();
function getW(P) {
  return pointWindowSizes.get(P) || 1;
}
function assert0(n) {
  if (n !== _0n3)
    throw new Error("invalid wNAF");
}
var wNAF = class {
  BASE;
  ZERO;
  Fn;
  bits;
  // Parametrized with a given Point class (not individual point)
  constructor(Point, bits) {
    this.BASE = Point.BASE;
    this.ZERO = Point.ZERO;
    this.Fn = Point.Fn;
    this.bits = bits;
  }
  // non-const time multiplication ladder
  _unsafeLadder(elm, n, p = this.ZERO) {
    let d = elm;
    while (n > _0n3) {
      if (n & _1n3)
        p = p.add(d);
      d = d.double();
      n >>= _1n3;
    }
    return p;
  }
  /**
   * Creates a wNAF precomputation window. Used for caching.
   * Default window size is set by `utils.precompute()` and is equal to 8.
   * Number of precomputed points depends on the curve size:
   * 2^(𝑊−1) * (Math.ceil(𝑛 / 𝑊) + 1), where:
   * - 𝑊 is the window size
   * - 𝑛 is the bitlength of the curve order.
   * For a 256-bit curve and window size 8, the number of precomputed points is 128 * 33 = 4224.
   * @param point Point instance
   * @param W window size
   * @returns precomputed point tables flattened to a single array
   */
  precomputeWindow(point, W) {
    const { windows, windowSize } = calcWOpts(W, this.bits);
    const points = [];
    let p = point;
    let base = p;
    for (let window2 = 0; window2 < windows; window2++) {
      base = p;
      points.push(base);
      for (let i4 = 1; i4 < windowSize; i4++) {
        base = base.add(p);
        points.push(base);
      }
      p = base.double();
    }
    return points;
  }
  /**
   * Implements ec multiplication using precomputed tables and w-ary non-adjacent form.
   * More compact implementation:
   * https://github.com/paulmillr/noble-secp256k1/blob/47cb1669b6e506ad66b35fe7d76132ae97465da2/index.ts#L502-L541
   * @returns real and fake (for const-time) points
   */
  wNAF(W, precomputes, n) {
    if (!this.Fn.isValid(n))
      throw new Error("invalid scalar");
    let p = this.ZERO;
    let f = this.BASE;
    const wo = calcWOpts(W, this.bits);
    for (let window2 = 0; window2 < wo.windows; window2++) {
      const { nextN, offset, isZero, isNeg, isNegF, offsetF } = calcOffsets(n, window2, wo);
      n = nextN;
      if (isZero) {
        f = f.add(negateCt(isNegF, precomputes[offsetF]));
      } else {
        p = p.add(negateCt(isNeg, precomputes[offset]));
      }
    }
    assert0(n);
    return { p, f };
  }
  /**
   * Implements ec unsafe (non const-time) multiplication using precomputed tables and w-ary non-adjacent form.
   * @param acc accumulator point to add result of multiplication
   * @returns point
   */
  wNAFUnsafe(W, precomputes, n, acc = this.ZERO) {
    const wo = calcWOpts(W, this.bits);
    for (let window2 = 0; window2 < wo.windows; window2++) {
      if (n === _0n3)
        break;
      const { nextN, offset, isZero, isNeg } = calcOffsets(n, window2, wo);
      n = nextN;
      if (isZero) {
        continue;
      } else {
        const item = precomputes[offset];
        acc = acc.add(isNeg ? item.negate() : item);
      }
    }
    assert0(n);
    return acc;
  }
  getPrecomputes(W, point, transform) {
    let comp = pointPrecomputes.get(point);
    if (!comp) {
      comp = this.precomputeWindow(point, W);
      if (W !== 1) {
        if (typeof transform === "function")
          comp = transform(comp);
        pointPrecomputes.set(point, comp);
      }
    }
    return comp;
  }
  cached(point, scalar, transform) {
    const W = getW(point);
    return this.wNAF(W, this.getPrecomputes(W, point, transform), scalar);
  }
  unsafe(point, scalar, transform, prev) {
    const W = getW(point);
    if (W === 1)
      return this._unsafeLadder(point, scalar, prev);
    return this.wNAFUnsafe(W, this.getPrecomputes(W, point, transform), scalar, prev);
  }
  // We calculate precomputes for elliptic curve point multiplication
  // using windowed method. This specifies window size and
  // stores precomputed values. Usually only base point would be precomputed.
  createCache(P, W) {
    validateW(W, this.bits);
    pointWindowSizes.set(P, W);
    pointPrecomputes.delete(P);
  }
  hasCache(elm) {
    return getW(elm) !== 1;
  }
};
function mulEndoUnsafe(Point, point, k1, k2) {
  let acc = point;
  let p1 = Point.ZERO;
  let p2 = Point.ZERO;
  while (k1 > _0n3 || k2 > _0n3) {
    if (k1 & _1n3)
      p1 = p1.add(acc);
    if (k2 & _1n3)
      p2 = p2.add(acc);
    acc = acc.double();
    k1 >>= _1n3;
    k2 >>= _1n3;
  }
  return { p1, p2 };
}
function createField(order, field, isLE2) {
  if (field) {
    if (field.ORDER !== order)
      throw new Error("Field.ORDER must match order: Fp == p, Fn == n");
    validateField(field);
    return field;
  } else {
    return Field(order, { isLE: isLE2 });
  }
}
function createCurveFields(type, CURVE, curveOpts = {}, FpFnLE) {
  if (FpFnLE === void 0)
    FpFnLE = type === "edwards";
  if (!CURVE || typeof CURVE !== "object")
    throw new Error(`expected valid ${type} CURVE object`);
  for (const p of ["p", "n", "h"]) {
    const val = CURVE[p];
    if (!(typeof val === "bigint" && val > _0n3))
      throw new Error(`CURVE.${p} must be positive bigint`);
  }
  const Fp = createField(CURVE.p, curveOpts.Fp, FpFnLE);
  const Fn = createField(CURVE.n, curveOpts.Fn, FpFnLE);
  const _b = type === "weierstrass" ? "b" : "d";
  const params = ["Gx", "Gy", "a", _b];
  for (const p of params) {
    if (!Fp.isValid(CURVE[p]))
      throw new Error(`CURVE.${p} must be valid field element of CURVE.Fp`);
  }
  CURVE = Object.freeze(Object.assign({}, CURVE));
  return { CURVE, Fp, Fn };
}
function createKeygen(randomSecretKey, getPublicKey4) {
  return function keygen(seed) {
    const secretKey = randomSecretKey(seed);
    return { secretKey, publicKey: getPublicKey4(secretKey) };
  };
}

// node_modules/@noble/hashes/hmac.js
var _HMAC = class {
  oHash;
  iHash;
  blockLen;
  outputLen;
  finished = false;
  destroyed = false;
  constructor(hash, key) {
    ahash(hash);
    abytes(key, void 0, "key");
    this.iHash = hash.create();
    if (typeof this.iHash.update !== "function")
      throw new Error("Expected instance of class which extends utils.Hash");
    this.blockLen = this.iHash.blockLen;
    this.outputLen = this.iHash.outputLen;
    const blockLen = this.blockLen;
    const pad3 = new Uint8Array(blockLen);
    pad3.set(key.length > blockLen ? hash.create().update(key).digest() : key);
    for (let i4 = 0; i4 < pad3.length; i4++)
      pad3[i4] ^= 54;
    this.iHash.update(pad3);
    this.oHash = hash.create();
    for (let i4 = 0; i4 < pad3.length; i4++)
      pad3[i4] ^= 54 ^ 92;
    this.oHash.update(pad3);
    clean(pad3);
  }
  update(buf) {
    aexists(this);
    this.iHash.update(buf);
    return this;
  }
  digestInto(out) {
    aexists(this);
    abytes(out, this.outputLen, "output");
    this.finished = true;
    this.iHash.digestInto(out);
    this.oHash.update(out);
    this.oHash.digestInto(out);
    this.destroy();
  }
  digest() {
    const out = new Uint8Array(this.oHash.outputLen);
    this.digestInto(out);
    return out;
  }
  _cloneInto(to) {
    to ||= Object.create(Object.getPrototypeOf(this), {});
    const { oHash, iHash, finished, destroyed, blockLen, outputLen } = this;
    to = to;
    to.finished = finished;
    to.destroyed = destroyed;
    to.blockLen = blockLen;
    to.outputLen = outputLen;
    to.oHash = oHash._cloneInto(to.oHash);
    to.iHash = iHash._cloneInto(to.iHash);
    return to;
  }
  clone() {
    return this._cloneInto();
  }
  destroy() {
    this.destroyed = true;
    this.oHash.destroy();
    this.iHash.destroy();
  }
};
var hmac = (hash, key, message) => new _HMAC(hash, key).update(message).digest();
hmac.create = (hash, key) => new _HMAC(hash, key);

// node_modules/@noble/curves/abstract/weierstrass.js
var divNearest = (num2, den) => (num2 + (num2 >= 0 ? den : -den) / _2n2) / den;
function _splitEndoScalar(k, basis, n) {
  const [[a1, b1], [a2, b2]] = basis;
  const c1 = divNearest(b2 * k, n);
  const c2 = divNearest(-b1 * k, n);
  let k1 = k - c1 * a1 - c2 * a2;
  let k2 = -c1 * b1 - c2 * b2;
  const k1neg = k1 < _0n4;
  const k2neg = k2 < _0n4;
  if (k1neg)
    k1 = -k1;
  if (k2neg)
    k2 = -k2;
  const MAX_NUM = bitMask(Math.ceil(bitLen(n) / 2)) + _1n4;
  if (k1 < _0n4 || k1 >= MAX_NUM || k2 < _0n4 || k2 >= MAX_NUM) {
    throw new Error("splitScalar (endomorphism): failed, k=" + k);
  }
  return { k1neg, k1, k2neg, k2 };
}
function validateSigFormat(format) {
  if (!["compact", "recovered", "der"].includes(format))
    throw new Error('Signature format must be "compact", "recovered", or "der"');
  return format;
}
function validateSigOpts(opts, def) {
  const optsn = {};
  for (let optName of Object.keys(def)) {
    optsn[optName] = opts[optName] === void 0 ? def[optName] : opts[optName];
  }
  abool(optsn.lowS, "lowS");
  abool(optsn.prehash, "prehash");
  if (optsn.format !== void 0)
    validateSigFormat(optsn.format);
  return optsn;
}
var DERErr = class extends Error {
  constructor(m = "") {
    super(m);
  }
};
var DER = {
  // asn.1 DER encoding utils
  Err: DERErr,
  // Basic building block is TLV (Tag-Length-Value)
  _tlv: {
    encode: (tag, data) => {
      const { Err: E } = DER;
      if (tag < 0 || tag > 256)
        throw new E("tlv.encode: wrong tag");
      if (data.length & 1)
        throw new E("tlv.encode: unpadded data");
      const dataLen = data.length / 2;
      const len = numberToHexUnpadded(dataLen);
      if (len.length / 2 & 128)
        throw new E("tlv.encode: long form length too big");
      const lenLen = dataLen > 127 ? numberToHexUnpadded(len.length / 2 | 128) : "";
      const t = numberToHexUnpadded(tag);
      return t + lenLen + len + data;
    },
    // v - value, l - left bytes (unparsed)
    decode(tag, data) {
      const { Err: E } = DER;
      let pos = 0;
      if (tag < 0 || tag > 256)
        throw new E("tlv.encode: wrong tag");
      if (data.length < 2 || data[pos++] !== tag)
        throw new E("tlv.decode: wrong tlv");
      const first = data[pos++];
      const isLong = !!(first & 128);
      let length = 0;
      if (!isLong)
        length = first;
      else {
        const lenLen = first & 127;
        if (!lenLen)
          throw new E("tlv.decode(long): indefinite length not supported");
        if (lenLen > 4)
          throw new E("tlv.decode(long): byte length is too big");
        const lengthBytes = data.subarray(pos, pos + lenLen);
        if (lengthBytes.length !== lenLen)
          throw new E("tlv.decode: length bytes not complete");
        if (lengthBytes[0] === 0)
          throw new E("tlv.decode(long): zero leftmost byte");
        for (const b of lengthBytes)
          length = length << 8 | b;
        pos += lenLen;
        if (length < 128)
          throw new E("tlv.decode(long): not minimal encoding");
      }
      const v = data.subarray(pos, pos + length);
      if (v.length !== length)
        throw new E("tlv.decode: wrong value length");
      return { v, l: data.subarray(pos + length) };
    }
  },
  // https://crypto.stackexchange.com/a/57734 Leftmost bit of first byte is 'negative' flag,
  // since we always use positive integers here. It must always be empty:
  // - add zero byte if exists
  // - if next byte doesn't have a flag, leading zero is not allowed (minimal encoding)
  _int: {
    encode(num2) {
      const { Err: E } = DER;
      if (num2 < _0n4)
        throw new E("integer: negative integers are not allowed");
      let hex = numberToHexUnpadded(num2);
      if (Number.parseInt(hex[0], 16) & 8)
        hex = "00" + hex;
      if (hex.length & 1)
        throw new E("unexpected DER parsing assertion: unpadded hex");
      return hex;
    },
    decode(data) {
      const { Err: E } = DER;
      if (data[0] & 128)
        throw new E("invalid signature integer: negative");
      if (data[0] === 0 && !(data[1] & 128))
        throw new E("invalid signature integer: unnecessary leading zero");
      return bytesToNumberBE(data);
    }
  },
  toSig(bytes) {
    const { Err: E, _int: int, _tlv: tlv } = DER;
    const data = abytes(bytes, void 0, "signature");
    const { v: seqBytes, l: seqLeftBytes } = tlv.decode(48, data);
    if (seqLeftBytes.length)
      throw new E("invalid signature: left bytes after parsing");
    const { v: rBytes, l: rLeftBytes } = tlv.decode(2, seqBytes);
    const { v: sBytes, l: sLeftBytes } = tlv.decode(2, rLeftBytes);
    if (sLeftBytes.length)
      throw new E("invalid signature: left bytes after parsing");
    return { r: int.decode(rBytes), s: int.decode(sBytes) };
  },
  hexFromSig(sig) {
    const { _tlv: tlv, _int: int } = DER;
    const rs = tlv.encode(2, int.encode(sig.r));
    const ss = tlv.encode(2, int.encode(sig.s));
    const seq = rs + ss;
    return tlv.encode(48, seq);
  }
};
var _0n4 = BigInt(0);
var _1n4 = BigInt(1);
var _2n2 = BigInt(2);
var _3n2 = BigInt(3);
var _4n2 = BigInt(4);
function weierstrass(params, extraOpts = {}) {
  const validated = createCurveFields("weierstrass", params, extraOpts);
  const { Fp, Fn } = validated;
  let CURVE = validated.CURVE;
  const { h: cofactor, n: CURVE_ORDER } = CURVE;
  validateObject(extraOpts, {}, {
    allowInfinityPoint: "boolean",
    clearCofactor: "function",
    isTorsionFree: "function",
    fromBytes: "function",
    toBytes: "function",
    endo: "object"
  });
  const { endo } = extraOpts;
  if (endo) {
    if (!Fp.is0(CURVE.a) || typeof endo.beta !== "bigint" || !Array.isArray(endo.basises)) {
      throw new Error('invalid endo: expected "beta": bigint and "basises": array');
    }
  }
  const lengths = getWLengths(Fp, Fn);
  function assertCompressionIsSupported() {
    if (!Fp.isOdd)
      throw new Error("compression is not supported: Field does not have .isOdd()");
  }
  function pointToBytes2(_c, point, isCompressed) {
    const { x, y } = point.toAffine();
    const bx = Fp.toBytes(x);
    abool(isCompressed, "isCompressed");
    if (isCompressed) {
      assertCompressionIsSupported();
      const hasEvenY = !Fp.isOdd(y);
      return concatBytes(pprefix(hasEvenY), bx);
    } else {
      return concatBytes(Uint8Array.of(4), bx, Fp.toBytes(y));
    }
  }
  function pointFromBytes(bytes) {
    abytes(bytes, void 0, "Point");
    const { publicKey: comp, publicKeyUncompressed: uncomp } = lengths;
    const length = bytes.length;
    const head = bytes[0];
    const tail = bytes.subarray(1);
    if (length === comp && (head === 2 || head === 3)) {
      const x = Fp.fromBytes(tail);
      if (!Fp.isValid(x))
        throw new Error("bad point: is not on curve, wrong x");
      const y2 = weierstrassEquation(x);
      let y;
      try {
        y = Fp.sqrt(y2);
      } catch (sqrtError) {
        const err = sqrtError instanceof Error ? ": " + sqrtError.message : "";
        throw new Error("bad point: is not on curve, sqrt error" + err);
      }
      assertCompressionIsSupported();
      const evenY = Fp.isOdd(y);
      const evenH = (head & 1) === 1;
      if (evenH !== evenY)
        y = Fp.neg(y);
      return { x, y };
    } else if (length === uncomp && head === 4) {
      const L = Fp.BYTES;
      const x = Fp.fromBytes(tail.subarray(0, L));
      const y = Fp.fromBytes(tail.subarray(L, L * 2));
      if (!isValidXY(x, y))
        throw new Error("bad point: is not on curve");
      return { x, y };
    } else {
      throw new Error(`bad point: got length ${length}, expected compressed=${comp} or uncompressed=${uncomp}`);
    }
  }
  const encodePoint = extraOpts.toBytes || pointToBytes2;
  const decodePoint = extraOpts.fromBytes || pointFromBytes;
  function weierstrassEquation(x) {
    const x2 = Fp.sqr(x);
    const x3 = Fp.mul(x2, x);
    return Fp.add(Fp.add(x3, Fp.mul(x, CURVE.a)), CURVE.b);
  }
  function isValidXY(x, y) {
    const left = Fp.sqr(y);
    const right = weierstrassEquation(x);
    return Fp.eql(left, right);
  }
  if (!isValidXY(CURVE.Gx, CURVE.Gy))
    throw new Error("bad curve params: generator point");
  const _4a3 = Fp.mul(Fp.pow(CURVE.a, _3n2), _4n2);
  const _27b2 = Fp.mul(Fp.sqr(CURVE.b), BigInt(27));
  if (Fp.is0(Fp.add(_4a3, _27b2)))
    throw new Error("bad curve params: a or b");
  function acoord(title, n, banZero = false) {
    if (!Fp.isValid(n) || banZero && Fp.is0(n))
      throw new Error(`bad point coordinate ${title}`);
    return n;
  }
  function aprjpoint(other) {
    if (!(other instanceof Point))
      throw new Error("Weierstrass Point expected");
  }
  function splitEndoScalarN(k) {
    if (!endo || !endo.basises)
      throw new Error("no endo");
    return _splitEndoScalar(k, endo.basises, Fn.ORDER);
  }
  const toAffineMemo = memoized((p, iz) => {
    const { X, Y, Z } = p;
    if (Fp.eql(Z, Fp.ONE))
      return { x: X, y: Y };
    const is0 = p.is0();
    if (iz == null)
      iz = is0 ? Fp.ONE : Fp.inv(Z);
    const x = Fp.mul(X, iz);
    const y = Fp.mul(Y, iz);
    const zz = Fp.mul(Z, iz);
    if (is0)
      return { x: Fp.ZERO, y: Fp.ZERO };
    if (!Fp.eql(zz, Fp.ONE))
      throw new Error("invZ was invalid");
    return { x, y };
  });
  const assertValidMemo = memoized((p) => {
    if (p.is0()) {
      if (extraOpts.allowInfinityPoint && !Fp.is0(p.Y))
        return;
      throw new Error("bad point: ZERO");
    }
    const { x, y } = p.toAffine();
    if (!Fp.isValid(x) || !Fp.isValid(y))
      throw new Error("bad point: x or y not field elements");
    if (!isValidXY(x, y))
      throw new Error("bad point: equation left != right");
    if (!p.isTorsionFree())
      throw new Error("bad point: not in prime-order subgroup");
    return true;
  });
  function finishEndo(endoBeta, k1p, k2p, k1neg, k2neg) {
    k2p = new Point(Fp.mul(k2p.X, endoBeta), k2p.Y, k2p.Z);
    k1p = negateCt(k1neg, k1p);
    k2p = negateCt(k2neg, k2p);
    return k1p.add(k2p);
  }
  class Point {
    // base / generator point
    static BASE = new Point(CURVE.Gx, CURVE.Gy, Fp.ONE);
    // zero / infinity / identity point
    static ZERO = new Point(Fp.ZERO, Fp.ONE, Fp.ZERO);
    // 0, 1, 0
    // math field
    static Fp = Fp;
    // scalar field
    static Fn = Fn;
    X;
    Y;
    Z;
    /** Does NOT validate if the point is valid. Use `.assertValidity()`. */
    constructor(X, Y, Z) {
      this.X = acoord("x", X);
      this.Y = acoord("y", Y, true);
      this.Z = acoord("z", Z);
      Object.freeze(this);
    }
    static CURVE() {
      return CURVE;
    }
    /** Does NOT validate if the point is valid. Use `.assertValidity()`. */
    static fromAffine(p) {
      const { x, y } = p || {};
      if (!p || !Fp.isValid(x) || !Fp.isValid(y))
        throw new Error("invalid affine point");
      if (p instanceof Point)
        throw new Error("projective point not allowed");
      if (Fp.is0(x) && Fp.is0(y))
        return Point.ZERO;
      return new Point(x, y, Fp.ONE);
    }
    static fromBytes(bytes) {
      const P = Point.fromAffine(decodePoint(abytes(bytes, void 0, "point")));
      P.assertValidity();
      return P;
    }
    static fromHex(hex) {
      return Point.fromBytes(hexToBytes(hex));
    }
    get x() {
      return this.toAffine().x;
    }
    get y() {
      return this.toAffine().y;
    }
    /**
     *
     * @param windowSize
     * @param isLazy true will defer table computation until the first multiplication
     * @returns
     */
    precompute(windowSize = 8, isLazy = true) {
      wnaf.createCache(this, windowSize);
      if (!isLazy)
        this.multiply(_3n2);
      return this;
    }
    // TODO: return `this`
    /** A point on curve is valid if it conforms to equation. */
    assertValidity() {
      assertValidMemo(this);
    }
    hasEvenY() {
      const { y } = this.toAffine();
      if (!Fp.isOdd)
        throw new Error("Field doesn't support isOdd");
      return !Fp.isOdd(y);
    }
    /** Compare one point to another. */
    equals(other) {
      aprjpoint(other);
      const { X: X1, Y: Y1, Z: Z1 } = this;
      const { X: X2, Y: Y2, Z: Z2 } = other;
      const U1 = Fp.eql(Fp.mul(X1, Z2), Fp.mul(X2, Z1));
      const U2 = Fp.eql(Fp.mul(Y1, Z2), Fp.mul(Y2, Z1));
      return U1 && U2;
    }
    /** Flips point to one corresponding to (x, -y) in Affine coordinates. */
    negate() {
      return new Point(this.X, Fp.neg(this.Y), this.Z);
    }
    // Renes-Costello-Batina exception-free doubling formula.
    // There is 30% faster Jacobian formula, but it is not complete.
    // https://eprint.iacr.org/2015/1060, algorithm 3
    // Cost: 8M + 3S + 3*a + 2*b3 + 15add.
    double() {
      const { a, b } = CURVE;
      const b3 = Fp.mul(b, _3n2);
      const { X: X1, Y: Y1, Z: Z1 } = this;
      let X3 = Fp.ZERO, Y3 = Fp.ZERO, Z3 = Fp.ZERO;
      let t0 = Fp.mul(X1, X1);
      let t1 = Fp.mul(Y1, Y1);
      let t2 = Fp.mul(Z1, Z1);
      let t3 = Fp.mul(X1, Y1);
      t3 = Fp.add(t3, t3);
      Z3 = Fp.mul(X1, Z1);
      Z3 = Fp.add(Z3, Z3);
      X3 = Fp.mul(a, Z3);
      Y3 = Fp.mul(b3, t2);
      Y3 = Fp.add(X3, Y3);
      X3 = Fp.sub(t1, Y3);
      Y3 = Fp.add(t1, Y3);
      Y3 = Fp.mul(X3, Y3);
      X3 = Fp.mul(t3, X3);
      Z3 = Fp.mul(b3, Z3);
      t2 = Fp.mul(a, t2);
      t3 = Fp.sub(t0, t2);
      t3 = Fp.mul(a, t3);
      t3 = Fp.add(t3, Z3);
      Z3 = Fp.add(t0, t0);
      t0 = Fp.add(Z3, t0);
      t0 = Fp.add(t0, t2);
      t0 = Fp.mul(t0, t3);
      Y3 = Fp.add(Y3, t0);
      t2 = Fp.mul(Y1, Z1);
      t2 = Fp.add(t2, t2);
      t0 = Fp.mul(t2, t3);
      X3 = Fp.sub(X3, t0);
      Z3 = Fp.mul(t2, t1);
      Z3 = Fp.add(Z3, Z3);
      Z3 = Fp.add(Z3, Z3);
      return new Point(X3, Y3, Z3);
    }
    // Renes-Costello-Batina exception-free addition formula.
    // There is 30% faster Jacobian formula, but it is not complete.
    // https://eprint.iacr.org/2015/1060, algorithm 1
    // Cost: 12M + 0S + 3*a + 3*b3 + 23add.
    add(other) {
      aprjpoint(other);
      const { X: X1, Y: Y1, Z: Z1 } = this;
      const { X: X2, Y: Y2, Z: Z2 } = other;
      let X3 = Fp.ZERO, Y3 = Fp.ZERO, Z3 = Fp.ZERO;
      const a = CURVE.a;
      const b3 = Fp.mul(CURVE.b, _3n2);
      let t0 = Fp.mul(X1, X2);
      let t1 = Fp.mul(Y1, Y2);
      let t2 = Fp.mul(Z1, Z2);
      let t3 = Fp.add(X1, Y1);
      let t4 = Fp.add(X2, Y2);
      t3 = Fp.mul(t3, t4);
      t4 = Fp.add(t0, t1);
      t3 = Fp.sub(t3, t4);
      t4 = Fp.add(X1, Z1);
      let t5 = Fp.add(X2, Z2);
      t4 = Fp.mul(t4, t5);
      t5 = Fp.add(t0, t2);
      t4 = Fp.sub(t4, t5);
      t5 = Fp.add(Y1, Z1);
      X3 = Fp.add(Y2, Z2);
      t5 = Fp.mul(t5, X3);
      X3 = Fp.add(t1, t2);
      t5 = Fp.sub(t5, X3);
      Z3 = Fp.mul(a, t4);
      X3 = Fp.mul(b3, t2);
      Z3 = Fp.add(X3, Z3);
      X3 = Fp.sub(t1, Z3);
      Z3 = Fp.add(t1, Z3);
      Y3 = Fp.mul(X3, Z3);
      t1 = Fp.add(t0, t0);
      t1 = Fp.add(t1, t0);
      t2 = Fp.mul(a, t2);
      t4 = Fp.mul(b3, t4);
      t1 = Fp.add(t1, t2);
      t2 = Fp.sub(t0, t2);
      t2 = Fp.mul(a, t2);
      t4 = Fp.add(t4, t2);
      t0 = Fp.mul(t1, t4);
      Y3 = Fp.add(Y3, t0);
      t0 = Fp.mul(t5, t4);
      X3 = Fp.mul(t3, X3);
      X3 = Fp.sub(X3, t0);
      t0 = Fp.mul(t3, t1);
      Z3 = Fp.mul(t5, Z3);
      Z3 = Fp.add(Z3, t0);
      return new Point(X3, Y3, Z3);
    }
    subtract(other) {
      return this.add(other.negate());
    }
    is0() {
      return this.equals(Point.ZERO);
    }
    /**
     * Constant time multiplication.
     * Uses wNAF method. Windowed method may be 10% faster,
     * but takes 2x longer to generate and consumes 2x memory.
     * Uses precomputes when available.
     * Uses endomorphism for Koblitz curves.
     * @param scalar by which the point would be multiplied
     * @returns New point
     */
    multiply(scalar) {
      const { endo: endo2 } = extraOpts;
      if (!Fn.isValidNot0(scalar))
        throw new Error("invalid scalar: out of range");
      let point, fake;
      const mul3 = (n) => wnaf.cached(this, n, (p) => normalizeZ(Point, p));
      if (endo2) {
        const { k1neg, k1, k2neg, k2 } = splitEndoScalarN(scalar);
        const { p: k1p, f: k1f } = mul3(k1);
        const { p: k2p, f: k2f } = mul3(k2);
        fake = k1f.add(k2f);
        point = finishEndo(endo2.beta, k1p, k2p, k1neg, k2neg);
      } else {
        const { p, f } = mul3(scalar);
        point = p;
        fake = f;
      }
      return normalizeZ(Point, [point, fake])[0];
    }
    /**
     * Non-constant-time multiplication. Uses double-and-add algorithm.
     * It's faster, but should only be used when you don't care about
     * an exposed secret key e.g. sig verification, which works over *public* keys.
     */
    multiplyUnsafe(sc) {
      const { endo: endo2 } = extraOpts;
      const p = this;
      if (!Fn.isValid(sc))
        throw new Error("invalid scalar: out of range");
      if (sc === _0n4 || p.is0())
        return Point.ZERO;
      if (sc === _1n4)
        return p;
      if (wnaf.hasCache(this))
        return this.multiply(sc);
      if (endo2) {
        const { k1neg, k1, k2neg, k2 } = splitEndoScalarN(sc);
        const { p1, p2 } = mulEndoUnsafe(Point, p, k1, k2);
        return finishEndo(endo2.beta, p1, p2, k1neg, k2neg);
      } else {
        return wnaf.unsafe(p, sc);
      }
    }
    /**
     * Converts Projective point to affine (x, y) coordinates.
     * @param invertedZ Z^-1 (inverted zero) - optional, precomputation is useful for invertBatch
     */
    toAffine(invertedZ) {
      return toAffineMemo(this, invertedZ);
    }
    /**
     * Checks whether Point is free of torsion elements (is in prime subgroup).
     * Always torsion-free for cofactor=1 curves.
     */
    isTorsionFree() {
      const { isTorsionFree } = extraOpts;
      if (cofactor === _1n4)
        return true;
      if (isTorsionFree)
        return isTorsionFree(Point, this);
      return wnaf.unsafe(this, CURVE_ORDER).is0();
    }
    clearCofactor() {
      const { clearCofactor } = extraOpts;
      if (cofactor === _1n4)
        return this;
      if (clearCofactor)
        return clearCofactor(Point, this);
      return this.multiplyUnsafe(cofactor);
    }
    isSmallOrder() {
      return this.multiplyUnsafe(cofactor).is0();
    }
    toBytes(isCompressed = true) {
      abool(isCompressed, "isCompressed");
      this.assertValidity();
      return encodePoint(Point, this, isCompressed);
    }
    toHex(isCompressed = true) {
      return bytesToHex(this.toBytes(isCompressed));
    }
    toString() {
      return `<Point ${this.is0() ? "ZERO" : this.toHex()}>`;
    }
  }
  const bits = Fn.BITS;
  const wnaf = new wNAF(Point, extraOpts.endo ? Math.ceil(bits / 2) : bits);
  Point.BASE.precompute(8);
  return Point;
}
function pprefix(hasEvenY) {
  return Uint8Array.of(hasEvenY ? 2 : 3);
}
function getWLengths(Fp, Fn) {
  return {
    secretKey: Fn.BYTES,
    publicKey: 1 + Fp.BYTES,
    publicKeyUncompressed: 1 + 2 * Fp.BYTES,
    publicKeyHasPrefix: true,
    signature: 2 * Fn.BYTES
  };
}
function ecdh(Point, ecdhOpts = {}) {
  const { Fn } = Point;
  const randomBytes_ = ecdhOpts.randomBytes || randomBytes;
  const lengths = Object.assign(getWLengths(Point.Fp, Fn), { seed: getMinHashLength(Fn.ORDER) });
  function isValidSecretKey(secretKey) {
    try {
      const num2 = Fn.fromBytes(secretKey);
      return Fn.isValidNot0(num2);
    } catch (error) {
      return false;
    }
  }
  function isValidPublicKey(publicKey2, isCompressed) {
    const { publicKey: comp, publicKeyUncompressed } = lengths;
    try {
      const l = publicKey2.length;
      if (isCompressed === true && l !== comp)
        return false;
      if (isCompressed === false && l !== publicKeyUncompressed)
        return false;
      return !!Point.fromBytes(publicKey2);
    } catch (error) {
      return false;
    }
  }
  function randomSecretKey(seed = randomBytes_(lengths.seed)) {
    return mapHashToField(abytes(seed, lengths.seed, "seed"), Fn.ORDER);
  }
  function getPublicKey4(secretKey, isCompressed = true) {
    return Point.BASE.multiply(Fn.fromBytes(secretKey)).toBytes(isCompressed);
  }
  function isProbPub(item) {
    const { secretKey, publicKey: publicKey2, publicKeyUncompressed } = lengths;
    if (!isBytes(item))
      return void 0;
    if ("_lengths" in Fn && Fn._lengths || secretKey === publicKey2)
      return void 0;
    const l = abytes(item, void 0, "key").length;
    return l === publicKey2 || l === publicKeyUncompressed;
  }
  function getSharedSecret(secretKeyA, publicKeyB, isCompressed = true) {
    if (isProbPub(secretKeyA) === true)
      throw new Error("first arg must be private key");
    if (isProbPub(publicKeyB) === false)
      throw new Error("second arg must be public key");
    const s = Fn.fromBytes(secretKeyA);
    const b = Point.fromBytes(publicKeyB);
    return b.multiply(s).toBytes(isCompressed);
  }
  const utils = {
    isValidSecretKey,
    isValidPublicKey,
    randomSecretKey
  };
  const keygen = createKeygen(randomSecretKey, getPublicKey4);
  return Object.freeze({ getPublicKey: getPublicKey4, getSharedSecret, keygen, Point, utils, lengths });
}
function ecdsa(Point, hash, ecdsaOpts = {}) {
  ahash(hash);
  validateObject(ecdsaOpts, {}, {
    hmac: "function",
    lowS: "boolean",
    randomBytes: "function",
    bits2int: "function",
    bits2int_modN: "function"
  });
  ecdsaOpts = Object.assign({}, ecdsaOpts);
  const randomBytes3 = ecdsaOpts.randomBytes || randomBytes;
  const hmac2 = ecdsaOpts.hmac || ((key, msg) => hmac(hash, key, msg));
  const { Fp, Fn } = Point;
  const { ORDER: CURVE_ORDER, BITS: fnBits } = Fn;
  const { keygen, getPublicKey: getPublicKey4, getSharedSecret, utils, lengths } = ecdh(Point, ecdsaOpts);
  const defaultSigOpts = {
    prehash: true,
    lowS: typeof ecdsaOpts.lowS === "boolean" ? ecdsaOpts.lowS : true,
    format: "compact",
    extraEntropy: false
  };
  const hasLargeCofactor = CURVE_ORDER * _2n2 < Fp.ORDER;
  function isBiggerThanHalfOrder(number) {
    const HALF = CURVE_ORDER >> _1n4;
    return number > HALF;
  }
  function validateRS(title, num2) {
    if (!Fn.isValidNot0(num2))
      throw new Error(`invalid signature ${title}: out of range 1..Point.Fn.ORDER`);
    return num2;
  }
  function assertSmallCofactor() {
    if (hasLargeCofactor)
      throw new Error('"recovered" sig type is not supported for cofactor >2 curves');
  }
  function validateSigLength(bytes, format) {
    validateSigFormat(format);
    const size = lengths.signature;
    const sizer = format === "compact" ? size : format === "recovered" ? size + 1 : void 0;
    return abytes(bytes, sizer);
  }
  class Signature {
    r;
    s;
    recovery;
    constructor(r, s, recovery) {
      this.r = validateRS("r", r);
      this.s = validateRS("s", s);
      if (recovery != null) {
        assertSmallCofactor();
        if (![0, 1, 2, 3].includes(recovery))
          throw new Error("invalid recovery id");
        this.recovery = recovery;
      }
      Object.freeze(this);
    }
    static fromBytes(bytes, format = defaultSigOpts.format) {
      validateSigLength(bytes, format);
      let recid;
      if (format === "der") {
        const { r: r2, s: s2 } = DER.toSig(abytes(bytes));
        return new Signature(r2, s2);
      }
      if (format === "recovered") {
        recid = bytes[0];
        format = "compact";
        bytes = bytes.subarray(1);
      }
      const L = lengths.signature / 2;
      const r = bytes.subarray(0, L);
      const s = bytes.subarray(L, L * 2);
      return new Signature(Fn.fromBytes(r), Fn.fromBytes(s), recid);
    }
    static fromHex(hex, format) {
      return this.fromBytes(hexToBytes(hex), format);
    }
    assertRecovery() {
      const { recovery } = this;
      if (recovery == null)
        throw new Error("invalid recovery id: must be present");
      return recovery;
    }
    addRecoveryBit(recovery) {
      return new Signature(this.r, this.s, recovery);
    }
    recoverPublicKey(messageHash) {
      const { r, s } = this;
      const recovery = this.assertRecovery();
      const radj = recovery === 2 || recovery === 3 ? r + CURVE_ORDER : r;
      if (!Fp.isValid(radj))
        throw new Error("invalid recovery id: sig.r+curve.n != R.x");
      const x = Fp.toBytes(radj);
      const R = Point.fromBytes(concatBytes(pprefix((recovery & 1) === 0), x));
      const ir = Fn.inv(radj);
      const h = bits2int_modN(abytes(messageHash, void 0, "msgHash"));
      const u1 = Fn.create(-h * ir);
      const u2 = Fn.create(s * ir);
      const Q = Point.BASE.multiplyUnsafe(u1).add(R.multiplyUnsafe(u2));
      if (Q.is0())
        throw new Error("invalid recovery: point at infinify");
      Q.assertValidity();
      return Q;
    }
    // Signatures should be low-s, to prevent malleability.
    hasHighS() {
      return isBiggerThanHalfOrder(this.s);
    }
    toBytes(format = defaultSigOpts.format) {
      validateSigFormat(format);
      if (format === "der")
        return hexToBytes(DER.hexFromSig(this));
      const { r, s } = this;
      const rb = Fn.toBytes(r);
      const sb = Fn.toBytes(s);
      if (format === "recovered") {
        assertSmallCofactor();
        return concatBytes(Uint8Array.of(this.assertRecovery()), rb, sb);
      }
      return concatBytes(rb, sb);
    }
    toHex(format) {
      return bytesToHex(this.toBytes(format));
    }
  }
  const bits2int = ecdsaOpts.bits2int || function bits2int_def(bytes) {
    if (bytes.length > 8192)
      throw new Error("input is too large");
    const num2 = bytesToNumberBE(bytes);
    const delta = bytes.length * 8 - fnBits;
    return delta > 0 ? num2 >> BigInt(delta) : num2;
  };
  const bits2int_modN = ecdsaOpts.bits2int_modN || function bits2int_modN_def(bytes) {
    return Fn.create(bits2int(bytes));
  };
  const ORDER_MASK = bitMask(fnBits);
  function int2octets(num2) {
    aInRange("num < 2^" + fnBits, num2, _0n4, ORDER_MASK);
    return Fn.toBytes(num2);
  }
  function validateMsgAndHash(message, prehash) {
    abytes(message, void 0, "message");
    return prehash ? abytes(hash(message), void 0, "prehashed message") : message;
  }
  function prepSig(message, secretKey, opts) {
    const { lowS, prehash, extraEntropy } = validateSigOpts(opts, defaultSigOpts);
    message = validateMsgAndHash(message, prehash);
    const h1int = bits2int_modN(message);
    const d = Fn.fromBytes(secretKey);
    if (!Fn.isValidNot0(d))
      throw new Error("invalid private key");
    const seedArgs = [int2octets(d), int2octets(h1int)];
    if (extraEntropy != null && extraEntropy !== false) {
      const e = extraEntropy === true ? randomBytes3(lengths.secretKey) : extraEntropy;
      seedArgs.push(abytes(e, void 0, "extraEntropy"));
    }
    const seed = concatBytes(...seedArgs);
    const m = h1int;
    function k2sig(kBytes) {
      const k = bits2int(kBytes);
      if (!Fn.isValidNot0(k))
        return;
      const ik = Fn.inv(k);
      const q = Point.BASE.multiply(k).toAffine();
      const r = Fn.create(q.x);
      if (r === _0n4)
        return;
      const s = Fn.create(ik * Fn.create(m + r * d));
      if (s === _0n4)
        return;
      let recovery = (q.x === r ? 0 : 2) | Number(q.y & _1n4);
      let normS = s;
      if (lowS && isBiggerThanHalfOrder(s)) {
        normS = Fn.neg(s);
        recovery ^= 1;
      }
      return new Signature(r, normS, hasLargeCofactor ? void 0 : recovery);
    }
    return { seed, k2sig };
  }
  function sign(message, secretKey, opts = {}) {
    const { seed, k2sig } = prepSig(message, secretKey, opts);
    const drbg = createHmacDrbg(hash.outputLen, Fn.BYTES, hmac2);
    const sig = drbg(seed, k2sig);
    return sig.toBytes(opts.format);
  }
  function verify(signature, message, publicKey2, opts = {}) {
    const { lowS, prehash, format } = validateSigOpts(opts, defaultSigOpts);
    publicKey2 = abytes(publicKey2, void 0, "publicKey");
    message = validateMsgAndHash(message, prehash);
    if (!isBytes(signature)) {
      const end = signature instanceof Signature ? ", use sig.toBytes()" : "";
      throw new Error("verify expects Uint8Array signature" + end);
    }
    validateSigLength(signature, format);
    try {
      const sig = Signature.fromBytes(signature, format);
      const P = Point.fromBytes(publicKey2);
      if (lowS && sig.hasHighS())
        return false;
      const { r, s } = sig;
      const h = bits2int_modN(message);
      const is = Fn.inv(s);
      const u1 = Fn.create(h * is);
      const u2 = Fn.create(r * is);
      const R = Point.BASE.multiplyUnsafe(u1).add(P.multiplyUnsafe(u2));
      if (R.is0())
        return false;
      const v = Fn.create(R.x);
      return v === r;
    } catch (e) {
      return false;
    }
  }
  function recoverPublicKey(signature, message, opts = {}) {
    const { prehash } = validateSigOpts(opts, defaultSigOpts);
    message = validateMsgAndHash(message, prehash);
    return Signature.fromBytes(signature, "recovered").recoverPublicKey(message).toBytes();
  }
  return Object.freeze({
    keygen,
    getPublicKey: getPublicKey4,
    getSharedSecret,
    utils,
    lengths,
    Point,
    sign,
    verify,
    recoverPublicKey,
    Signature,
    hash
  });
}

// node_modules/@noble/curves/secp256k1.js
var secp256k1_CURVE = {
  p: BigInt("0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"),
  n: BigInt("0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"),
  h: BigInt(1),
  a: BigInt(0),
  b: BigInt(7),
  Gx: BigInt("0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
  Gy: BigInt("0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")
};
var secp256k1_ENDO = {
  beta: BigInt("0x7ae96a2b657c07106e64479eac3434e99cf0497512f58995c1396c28719501ee"),
  basises: [
    [BigInt("0x3086d221a7d46bcde86c90e49284eb15"), -BigInt("0xe4437ed6010e88286f547fa90abfe4c3")],
    [BigInt("0x114ca50f7a8e2f3f657c1108d9d44cfd8"), BigInt("0x3086d221a7d46bcde86c90e49284eb15")]
  ]
};
var _0n5 = /* @__PURE__ */ BigInt(0);
var _2n3 = /* @__PURE__ */ BigInt(2);
function sqrtMod(y) {
  const P = secp256k1_CURVE.p;
  const _3n3 = BigInt(3), _6n = BigInt(6), _11n = BigInt(11), _22n = BigInt(22);
  const _23n = BigInt(23), _44n = BigInt(44), _88n = BigInt(88);
  const b2 = y * y * y % P;
  const b3 = b2 * b2 * y % P;
  const b6 = pow2(b3, _3n3, P) * b3 % P;
  const b9 = pow2(b6, _3n3, P) * b3 % P;
  const b11 = pow2(b9, _2n3, P) * b2 % P;
  const b22 = pow2(b11, _11n, P) * b11 % P;
  const b44 = pow2(b22, _22n, P) * b22 % P;
  const b88 = pow2(b44, _44n, P) * b44 % P;
  const b176 = pow2(b88, _88n, P) * b88 % P;
  const b220 = pow2(b176, _44n, P) * b44 % P;
  const b223 = pow2(b220, _3n3, P) * b3 % P;
  const t1 = pow2(b223, _23n, P) * b22 % P;
  const t2 = pow2(t1, _6n, P) * b2 % P;
  const root = pow2(t2, _2n3, P);
  if (!Fpk1.eql(Fpk1.sqr(root), y))
    throw new Error("Cannot find square root");
  return root;
}
var Fpk1 = Field(secp256k1_CURVE.p, { sqrt: sqrtMod });
var Pointk1 = /* @__PURE__ */ weierstrass(secp256k1_CURVE, {
  Fp: Fpk1,
  endo: secp256k1_ENDO
});
var secp256k1 = /* @__PURE__ */ ecdsa(Pointk1, sha256);
var TAGGED_HASH_PREFIXES = {};
function taggedHash(tag, ...messages2) {
  let tagP = TAGGED_HASH_PREFIXES[tag];
  if (tagP === void 0) {
    const tagH = sha256(asciiToBytes(tag));
    tagP = concatBytes(tagH, tagH);
    TAGGED_HASH_PREFIXES[tag] = tagP;
  }
  return sha256(concatBytes(tagP, ...messages2));
}
var pointToBytes = (point) => point.toBytes(true).slice(1);
var hasEven = (y) => y % _2n3 === _0n5;
function schnorrGetExtPubKey(priv) {
  const { Fn, BASE } = Pointk1;
  const d_ = Fn.fromBytes(priv);
  const p = BASE.multiply(d_);
  const scalar = hasEven(p.y) ? d_ : Fn.neg(d_);
  return { scalar, bytes: pointToBytes(p) };
}
function lift_x(x) {
  const Fp = Fpk1;
  if (!Fp.isValidNot0(x))
    throw new Error("invalid x: Fail if x \u2265 p");
  const xx = Fp.create(x * x);
  const c = Fp.create(xx * x + BigInt(7));
  let y = Fp.sqrt(c);
  if (!hasEven(y))
    y = Fp.neg(y);
  const p = Pointk1.fromAffine({ x, y });
  p.assertValidity();
  return p;
}
var num = bytesToNumberBE;
function challenge(...args) {
  return Pointk1.Fn.create(num(taggedHash("BIP0340/challenge", ...args)));
}
function schnorrGetPublicKey(secretKey) {
  return schnorrGetExtPubKey(secretKey).bytes;
}
function schnorrSign(message, secretKey, auxRand = randomBytes(32)) {
  const { Fn } = Pointk1;
  const m = abytes(message, void 0, "message");
  const { bytes: px, scalar: d } = schnorrGetExtPubKey(secretKey);
  const a = abytes(auxRand, 32, "auxRand");
  const t = Fn.toBytes(d ^ num(taggedHash("BIP0340/aux", a)));
  const rand = taggedHash("BIP0340/nonce", t, px, m);
  const { bytes: rx, scalar: k } = schnorrGetExtPubKey(rand);
  const e = challenge(rx, px, m);
  const sig = new Uint8Array(64);
  sig.set(rx, 0);
  sig.set(Fn.toBytes(Fn.create(k + e * d)), 32);
  if (!schnorrVerify(sig, m, px))
    throw new Error("sign: Invalid signature produced");
  return sig;
}
function schnorrVerify(signature, message, publicKey2) {
  const { Fp, Fn, BASE } = Pointk1;
  const sig = abytes(signature, 64, "signature");
  const m = abytes(message, void 0, "message");
  const pub = abytes(publicKey2, 32, "publicKey");
  try {
    const P = lift_x(num(pub));
    const r = num(sig.subarray(0, 32));
    if (!Fp.isValidNot0(r))
      return false;
    const s = num(sig.subarray(32, 64));
    if (!Fn.isValidNot0(s))
      return false;
    const e = challenge(Fn.toBytes(r), pointToBytes(P), m);
    const R = BASE.multiplyUnsafe(s).add(P.multiplyUnsafe(Fn.neg(e)));
    const { x, y } = R.toAffine();
    if (R.is0() || !hasEven(y) || x !== r)
      return false;
    return true;
  } catch (error) {
    return false;
  }
}
var schnorr = /* @__PURE__ */ (() => {
  const size = 32;
  const seedLength = 48;
  const randomSecretKey = (seed = randomBytes(seedLength)) => {
    return mapHashToField(seed, secp256k1_CURVE.n);
  };
  return {
    keygen: createKeygen(randomSecretKey, schnorrGetPublicKey),
    getPublicKey: schnorrGetPublicKey,
    sign: schnorrSign,
    verify: schnorrVerify,
    Point: Pointk1,
    utils: {
      randomSecretKey,
      taggedHash,
      lift_x,
      pointToBytes
    },
    lengths: {
      secretKey: size,
      publicKey: size,
      publicKeyHasPrefix: false,
      signature: size * 2,
      seed: seedLength
    }
  };
})();

// node_modules/nostr-tools/lib/esm/pure.js
var utf8Decoder = new TextDecoder("utf-8");
var utf8Encoder = new TextEncoder();
function isHex32(input) {
  if (input.length !== 64)
    return false;
  for (let i22 = 0; i22 < 64; i22++) {
    let cc = input.charCodeAt(i22);
    if (isNaN(cc) || cc < 48 || cc > 102 || cc > 57 && cc < 97) {
      return false;
    }
  }
  return true;
}
var verifiedSymbol = Symbol("verified");
var isRecord = (obj) => obj instanceof Object;
function validateEvent(event) {
  if (!isRecord(event))
    return false;
  if (typeof event.kind !== "number")
    return false;
  if (typeof event.content !== "string")
    return false;
  if (typeof event.created_at !== "number")
    return false;
  if (typeof event.pubkey !== "string")
    return false;
  if (!isHex32(event.pubkey))
    return false;
  if (!Array.isArray(event.tags))
    return false;
  for (let i22 = 0; i22 < event.tags.length; i22++) {
    let tag = event.tags[i22];
    if (!Array.isArray(tag))
      return false;
    for (let j = 0; j < tag.length; j++) {
      if (typeof tag[j] !== "string")
        return false;
    }
  }
  return true;
}
var JS = class {
  generateSecretKey() {
    return schnorr.utils.randomSecretKey();
  }
  getPublicKey(secretKey) {
    return bytesToHex(schnorr.getPublicKey(secretKey));
  }
  finalizeEvent(t, secretKey) {
    const event = t;
    event.pubkey = bytesToHex(schnorr.getPublicKey(secretKey));
    event.id = getEventHash(event);
    event.sig = bytesToHex(schnorr.sign(hexToBytes(getEventHash(event)), secretKey));
    event[verifiedSymbol] = true;
    return event;
  }
  verifyEvent(event) {
    if (typeof event[verifiedSymbol] === "boolean")
      return event[verifiedSymbol];
    try {
      const hash = getEventHash(event);
      if (hash !== event.id) {
        event[verifiedSymbol] = false;
        return false;
      }
      const valid = schnorr.verify(hexToBytes(event.sig), hexToBytes(hash), hexToBytes(event.pubkey));
      event[verifiedSymbol] = valid;
      return valid;
    } catch (err) {
      event[verifiedSymbol] = false;
      return false;
    }
  }
};
function serializeEvent(evt) {
  if (!validateEvent(evt))
    throw new Error("can't serialize event with wrong or missing properties");
  return JSON.stringify([0, evt.pubkey, evt.created_at, evt.kind, evt.tags, evt.content]);
}
function getEventHash(event) {
  let eventHash = sha256(utf8Encoder.encode(serializeEvent(event)));
  return bytesToHex(eventHash);
}
var i = new JS();
var generateSecretKey = i.generateSecretKey;
var getPublicKey = i.getPublicKey;
var finalizeEvent = i.finalizeEvent;
var verifyEvent = i.verifyEvent;

// node_modules/nostr-tools/lib/esm/pool.js
var utf8Decoder2 = new TextDecoder("utf-8");
var utf8Encoder2 = new TextEncoder();
function normalizeURL(url) {
  try {
    if (url.indexOf("://") === -1)
      url = "wss://" + url;
    let p = new URL(url);
    if (p.protocol === "http:")
      p.protocol = "ws:";
    else if (p.protocol === "https:")
      p.protocol = "wss:";
    p.pathname = p.pathname.replace(/\/+/g, "/");
    if (p.pathname.endsWith("/"))
      p.pathname = p.pathname.slice(0, -1);
    if (p.port === "80" && p.protocol === "ws:" || p.port === "443" && p.protocol === "wss:")
      p.port = "";
    p.searchParams.sort();
    p.hash = "";
    return p.toString();
  } catch (e) {
    throw new Error(`Invalid URL: ${url}`);
  }
}
function isHex322(input) {
  if (input.length !== 64)
    return false;
  for (let i22 = 0; i22 < 64; i22++) {
    let cc = input.charCodeAt(i22);
    if (isNaN(cc) || cc < 48 || cc > 102 || cc > 57 && cc < 97) {
      return false;
    }
  }
  return true;
}
var verifiedSymbol2 = Symbol("verified");
var isRecord2 = (obj) => obj instanceof Object;
function validateEvent2(event) {
  if (!isRecord2(event))
    return false;
  if (typeof event.kind !== "number")
    return false;
  if (typeof event.content !== "string")
    return false;
  if (typeof event.created_at !== "number")
    return false;
  if (typeof event.pubkey !== "string")
    return false;
  if (!isHex322(event.pubkey))
    return false;
  if (!Array.isArray(event.tags))
    return false;
  for (let i22 = 0; i22 < event.tags.length; i22++) {
    let tag = event.tags[i22];
    if (!Array.isArray(tag))
      return false;
    for (let j = 0; j < tag.length; j++) {
      if (typeof tag[j] !== "string")
        return false;
    }
  }
  return true;
}
var JS2 = class {
  generateSecretKey() {
    return schnorr.utils.randomSecretKey();
  }
  getPublicKey(secretKey) {
    return bytesToHex(schnorr.getPublicKey(secretKey));
  }
  finalizeEvent(t, secretKey) {
    const event = t;
    event.pubkey = bytesToHex(schnorr.getPublicKey(secretKey));
    event.id = getEventHash2(event);
    event.sig = bytesToHex(schnorr.sign(hexToBytes(getEventHash2(event)), secretKey));
    event[verifiedSymbol2] = true;
    return event;
  }
  verifyEvent(event) {
    if (typeof event[verifiedSymbol2] === "boolean")
      return event[verifiedSymbol2];
    try {
      const hash = getEventHash2(event);
      if (hash !== event.id) {
        event[verifiedSymbol2] = false;
        return false;
      }
      const valid = schnorr.verify(hexToBytes(event.sig), hexToBytes(hash), hexToBytes(event.pubkey));
      event[verifiedSymbol2] = valid;
      return valid;
    } catch (err) {
      event[verifiedSymbol2] = false;
      return false;
    }
  }
};
function serializeEvent2(evt) {
  if (!validateEvent2(evt))
    throw new Error("can't serialize event with wrong or missing properties");
  return JSON.stringify([0, evt.pubkey, evt.created_at, evt.kind, evt.tags, evt.content]);
}
function getEventHash2(event) {
  let eventHash = sha256(utf8Encoder2.encode(serializeEvent2(event)));
  return bytesToHex(eventHash);
}
var i2 = new JS2();
var generateSecretKey2 = i2.generateSecretKey;
var getPublicKey2 = i2.getPublicKey;
var finalizeEvent2 = i2.finalizeEvent;
var verifyEvent2 = i2.verifyEvent;
var ClientAuth = 22242;
function matchFilter(filter, event) {
  if (filter.ids && filter.ids.indexOf(event.id) === -1) {
    return false;
  }
  if (filter.kinds && filter.kinds.indexOf(event.kind) === -1) {
    return false;
  }
  if (filter.authors && filter.authors.indexOf(event.pubkey) === -1) {
    return false;
  }
  for (let f in filter) {
    if (f[0] === "#") {
      let tagName = f.slice(1);
      let values = filter[`#${tagName}`];
      if (values && !event.tags.find(([t, v]) => t === f.slice(1) && values.indexOf(v) !== -1))
        return false;
    }
  }
  if (filter.since && event.created_at < filter.since)
    return false;
  if (filter.until && event.created_at > filter.until)
    return false;
  return true;
}
function matchFilters(filters2, event) {
  for (let i22 = 0; i22 < filters2.length; i22++) {
    if (matchFilter(filters2[i22], event)) {
      return true;
    }
  }
  return false;
}
function getHex64(json, field) {
  let len = field.length + 3;
  let idx = json.indexOf(`"${field}":`) + len;
  let s = json.slice(idx).indexOf(`"`) + idx + 1;
  return json.slice(s, s + 64);
}
function getSubscriptionId(json) {
  let idx = json.slice(0, 22).indexOf(`"EVENT"`);
  if (idx === -1)
    return null;
  let pstart = json.slice(idx + 7 + 1).indexOf(`"`);
  if (pstart === -1)
    return null;
  let start = idx + 7 + 1 + pstart;
  let pend = json.slice(start + 1, 80).indexOf(`"`);
  if (pend === -1)
    return null;
  let end = start + 1 + pend;
  return json.slice(start + 1, end);
}
function makeAuthEvent(relayURL, challenge2) {
  return {
    kind: ClientAuth,
    created_at: Math.floor(Date.now() / 1e3),
    tags: [
      ["relay", relayURL],
      ["challenge", challenge2]
    ],
    content: ""
  };
}
var SendingOnClosedConnection = class extends Error {
  constructor(message, relay) {
    super(`Tried to send message '${message} on a closed connection to ${relay}.`);
    this.name = "SendingOnClosedConnection";
  }
};
var AbstractRelay = class {
  url;
  _connected = false;
  onclose = null;
  onnotice = (msg) => console.debug(`NOTICE from ${this.url}: ${msg}`);
  onauth;
  baseEoseTimeout = 4400;
  publishTimeout = 4400;
  pingFrequency = 29e3;
  pingTimeout = 2e4;
  resubscribeBackoff = [1e4, 1e4, 1e4, 2e4, 2e4, 3e4, 6e4];
  openSubs = /* @__PURE__ */ new Map();
  enablePing;
  enableReconnect;
  idleTimeout = 0;
  idleSince = Date.now();
  ongoingOperations = 0;
  reconnectTimeoutHandle;
  pingIntervalHandle;
  reconnectAttempts = 0;
  skipReconnection = false;
  idleTimeoutHandle;
  connectionPromise;
  openCountRequests = /* @__PURE__ */ new Map();
  openEventPublishes = /* @__PURE__ */ new Map();
  ws;
  challenge;
  authPromise;
  serial = 0;
  verifyEvent;
  _WebSocket;
  constructor(url, opts) {
    this.url = normalizeURL(url);
    this.verifyEvent = opts.verifyEvent;
    this._WebSocket = opts.websocketImplementation || WebSocket;
    this.enablePing = opts.enablePing;
    this.enableReconnect = opts.enableReconnect || false;
    if (opts.idleTimeout)
      this.idleTimeout = opts.idleTimeout;
  }
  static async connect(url, opts) {
    const relay = new AbstractRelay(url, opts);
    await relay.connect(opts);
    return relay;
  }
  closeAllSubscriptions(reason) {
    for (let [_, sub] of this.openSubs) {
      sub.close(reason);
    }
    this.openSubs.clear();
    for (let [_, ep] of this.openEventPublishes) {
      ep.reject(new Error(reason));
    }
    this.openEventPublishes.clear();
    for (let [_, cr] of this.openCountRequests) {
      cr.reject(new Error(reason));
    }
    this.openCountRequests.clear();
  }
  get connected() {
    return this._connected;
  }
  clearIdleTimeout() {
    if (this.idleTimeoutHandle) {
      clearTimeout(this.idleTimeoutHandle);
      this.idleTimeoutHandle = void 0;
    }
  }
  scheduleIdleClose() {
    this.clearIdleTimeout();
    if (this.idleTimeout > 0) {
      this.idleTimeoutHandle = setTimeout(() => {
        if (this.ongoingOperations === 0 && this.idleSince) {
          this.close();
        }
      }, this.idleTimeout);
    }
  }
  async reconnect() {
    const backoff = this.resubscribeBackoff[Math.min(this.reconnectAttempts, this.resubscribeBackoff.length - 1)];
    this.reconnectAttempts++;
    this.reconnectTimeoutHandle = setTimeout(async () => {
      try {
        await this.connect();
      } catch (err) {
      }
    }, backoff);
  }
  handleHardClose(reason) {
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
    }
    if (this.pingIntervalHandle) {
      clearInterval(this.pingIntervalHandle);
      this.pingIntervalHandle = void 0;
    }
    this._connected = false;
    this.connectionPromise = void 0;
    this.idleSince = void 0;
    this.clearIdleTimeout();
    if (this.enableReconnect && !this.skipReconnection) {
      this.reconnect();
    } else {
      this.onclose?.();
      this.closeAllSubscriptions(reason);
    }
  }
  async connect(opts) {
    let connectionTimeoutHandle;
    if (this.connectionPromise)
      return this.connectionPromise;
    this.challenge = void 0;
    this.authPromise = void 0;
    this.skipReconnection = false;
    this.connectionPromise = new Promise((resolve, reject) => {
      if (opts?.timeout) {
        connectionTimeoutHandle = setTimeout(() => {
          reject("connection timed out");
          this.connectionPromise = void 0;
          if (this.reconnectAttempts === 0) {
            this.skipReconnection = true;
          }
          this.ws?.close?.();
          this.handleHardClose("relay connection timed out");
        }, opts.timeout);
      }
      if (opts?.abort) {
        opts.abort.onabort = reject;
      }
      try {
        this.ws = new this._WebSocket(this.url);
      } catch (err) {
        clearTimeout(connectionTimeoutHandle);
        reject(err);
        return;
      }
      this.ws.onopen = () => {
        if (this.reconnectTimeoutHandle) {
          clearTimeout(this.reconnectTimeoutHandle);
          this.reconnectTimeoutHandle = void 0;
        }
        clearTimeout(connectionTimeoutHandle);
        this._connected = true;
        const isReconnection = this.reconnectAttempts > 0;
        this.reconnectAttempts = 0;
        for (const sub of this.openSubs.values()) {
          sub.eosed = false;
          if (isReconnection) {
            for (let f = 0; f < sub.filters.length; f++) {
              if (sub.lastEmitted) {
                sub.filters[f].since = sub.lastEmitted + 1;
              }
            }
          }
          sub.fire();
        }
        if (this.enablePing) {
          this.pingIntervalHandle = setInterval(() => this.pingpong(), this.pingFrequency);
        }
        resolve();
      };
      this.ws.onerror = () => {
        clearTimeout(connectionTimeoutHandle);
        reject("connection failed");
        this.connectionPromise = void 0;
        if (this.reconnectAttempts === 0) {
          this.skipReconnection = true;
        }
        this.ws?.close?.();
        this.handleHardClose("relay connection failed");
      };
      this.ws.onclose = (ev) => {
        clearTimeout(connectionTimeoutHandle);
        reject(ev.message || "websocket closed");
        this.handleHardClose("relay connection closed");
      };
      this.ws.onmessage = this._onmessage.bind(this);
    });
    return this.connectionPromise;
  }
  waitForPingPong() {
    return new Promise((resolve) => {
      ;
      this.ws.once("pong", () => resolve(true));
      this.ws.ping();
    });
  }
  waitForDummyReq() {
    return new Promise((resolve, reject) => {
      if (!this.connectionPromise)
        return reject(new Error(`no connection to ${this.url}, can't ping`));
      try {
        const sub = this.subscribe(
          [{ ids: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], limit: 1 }],
          {
            label: "<forced-ping>",
            oneose: () => {
              resolve(true);
              sub.close();
            },
            onclose() {
              resolve(true);
            },
            eoseTimeout: this.pingTimeout + 1e3
          }
        );
      } catch (err) {
        reject(err);
      }
    });
  }
  async pingpong() {
    if (this.ws?.readyState === 1) {
      const result = await Promise.any([
        this.ws && this.ws.ping && this.ws.once ? this.waitForPingPong() : this.waitForDummyReq(),
        new Promise((res) => setTimeout(() => res(false), this.pingTimeout))
      ]);
      if (!result) {
        if (this.ws?.readyState === this._WebSocket.OPEN) {
          this.ws?.close();
        }
      }
    }
  }
  async send(message) {
    if (!this.connectionPromise)
      throw new SendingOnClosedConnection(message, this.url);
    this.connectionPromise.then(() => {
      this.ws?.send(message);
    });
  }
  async auth(signAuthEvent) {
    const challenge2 = this.challenge;
    if (!challenge2)
      throw new Error("can't perform auth, no challenge was received");
    if (this.authPromise)
      return this.authPromise;
    this.authPromise = new Promise(async (resolve, reject) => {
      try {
        let evt = await signAuthEvent(makeAuthEvent(this.url, challenge2));
        let timeout = setTimeout(() => {
          let ep = this.openEventPublishes.get(evt.id);
          if (ep) {
            ep.reject(new Error("auth timed out"));
            this.openEventPublishes.delete(evt.id);
          }
        }, this.publishTimeout);
        this.openEventPublishes.set(evt.id, { resolve, reject, timeout });
        this.send('["AUTH",' + JSON.stringify(evt) + "]");
      } catch (err) {
        console.warn("subscribe auth function failed:", err);
      }
    });
    return this.authPromise;
  }
  async publish(event) {
    this.idleSince = void 0;
    this.clearIdleTimeout();
    this.ongoingOperations++;
    const ret = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const ep = this.openEventPublishes.get(event.id);
        if (ep) {
          ep.reject(new Error("publish timed out"));
          this.openEventPublishes.delete(event.id);
        }
      }, this.publishTimeout);
      this.openEventPublishes.set(event.id, { resolve, reject, timeout });
    });
    try {
      await this.send('["EVENT",' + JSON.stringify(event) + "]");
    } catch (err) {
      const ep = this.openEventPublishes.get(event.id);
      if (ep) {
        ep.reject(err);
        this.openEventPublishes.delete(event.id);
      }
    }
    this.ongoingOperations--;
    if (this.ongoingOperations === 0) {
      this.idleSince = Date.now();
      this.scheduleIdleClose();
    }
    return ret;
  }
  async count(filters2, params) {
    return (await this.countWithHLL(filters2, params)).count;
  }
  async countWithHLL(filters2, params) {
    this.serial++;
    const id = params?.id || "count:" + this.serial;
    const ret = new Promise((resolve, reject) => {
      this.openCountRequests.set(id, { resolve, reject });
    });
    try {
      await this.send('["COUNT","' + id + '",' + JSON.stringify(filters2).substring(1));
    } catch (err) {
      const cr = this.openCountRequests.get(id);
      if (cr) {
        cr.reject(err);
        this.openCountRequests.delete(id);
      }
    }
    return ret;
  }
  subscribe(filters2, params) {
    if (params.label !== "<forced-ping>") {
      this.idleSince = void 0;
      this.clearIdleTimeout();
      this.ongoingOperations++;
    }
    const sub = this.prepareSubscription(filters2, params);
    sub.fire();
    if (params.abort) {
      params.abort.onabort = () => sub.close(String(params.abort.reason || "<aborted>"));
    }
    return sub;
  }
  prepareSubscription(filters2, params) {
    this.serial++;
    const id = params.id || (params.label ? params.label + ":" : "sub:") + this.serial;
    const sub = new Subscription(this, id, filters2, params);
    this.openSubs.set(id, sub);
    return sub;
  }
  close() {
    this.skipReconnection = true;
    if (this.reconnectTimeoutHandle) {
      clearTimeout(this.reconnectTimeoutHandle);
      this.reconnectTimeoutHandle = void 0;
    }
    if (this.pingIntervalHandle) {
      clearInterval(this.pingIntervalHandle);
      this.pingIntervalHandle = void 0;
    }
    this.closeAllSubscriptions("relay connection closed by us");
    this._connected = false;
    this.connectionPromise = void 0;
    this.idleSince = void 0;
    this.clearIdleTimeout();
    this.onclose?.();
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
      if (this.ws.readyState !== this._WebSocket.CLOSING && this.ws.readyState !== this._WebSocket.CLOSED) {
        this.ws.close();
      }
    }
  }
  _onmessage(ev) {
    const json = ev.data;
    if (!json) {
      return;
    }
    const subid = getSubscriptionId(json);
    if (subid) {
      const so = this.openSubs.get(subid);
      if (!so) {
        return;
      }
      const id = getHex64(json, "id");
      const alreadyHave = so.alreadyHaveEvent?.(id);
      so.receivedEvent?.(this, id);
      if (alreadyHave) {
        return;
      }
    }
    try {
      let data = JSON.parse(json);
      switch (data[0]) {
        case "EVENT": {
          const so = this.openSubs.get(data[1]);
          const event = data[2];
          if (matchFilters(so.filters, event) && this.verifyEvent(event, this.url)) {
            so.onevent(event);
          } else {
            so.oninvalidevent?.(event);
          }
          if (!so.lastEmitted || so.lastEmitted < event.created_at)
            so.lastEmitted = event.created_at;
          return;
        }
        case "COUNT": {
          const id = data[1];
          const payload = data[2];
          const cr = this.openCountRequests.get(id);
          if (cr) {
            cr.resolve(payload);
            this.openCountRequests.delete(id);
          }
          return;
        }
        case "EOSE": {
          const so = this.openSubs.get(data[1]);
          if (!so)
            return;
          so.receivedEose();
          return;
        }
        case "OK": {
          const id = data[1];
          const ok = data[2];
          const reason = data[3];
          const ep = this.openEventPublishes.get(id);
          if (ep) {
            clearTimeout(ep.timeout);
            if (ok)
              ep.resolve(reason);
            else
              ep.reject(new Error(reason));
            this.openEventPublishes.delete(id);
          }
          return;
        }
        case "CLOSED": {
          const id = data[1];
          const so = this.openSubs.get(id);
          if (!so) {
            const cr = this.openCountRequests.get(id);
            if (cr) {
              cr.reject(new Error(data[2]));
              this.openCountRequests.delete(id);
            }
            return;
          }
          so.closed = true;
          so.close(data[2]);
          return;
        }
        case "NOTICE": {
          this.onnotice(data[1]);
          return;
        }
        case "AUTH": {
          this.challenge = data[1];
          if (this.onauth) {
            this.auth(this.onauth).catch((err) => {
              if (!(err instanceof SendingOnClosedConnection)) {
                throw err;
              }
            });
          }
          return;
        }
        default: {
          const so = this.openSubs.get(data[1]);
          so?.oncustom?.(data);
          return;
        }
      }
    } catch (err) {
      try {
        const [_, __, event] = JSON.parse(json);
        console.warn(`[nostr] relay ${this.url} error processing message:`, err, event);
      } catch (_) {
        console.warn(`[nostr] relay ${this.url} error processing message:`, err);
      }
      return;
    }
  }
};
var Subscription = class {
  relay;
  id;
  lastEmitted;
  closed = false;
  eosed = false;
  filters;
  alreadyHaveEvent;
  receivedEvent;
  onevent;
  oninvalidevent;
  oneose;
  onclose;
  oncustom;
  eoseTimeout;
  eoseTimeoutHandle;
  constructor(relay, id, filters2, params) {
    if (filters2.length === 0)
      throw new Error("subscription can't be created with zero filters");
    this.relay = relay;
    this.filters = filters2;
    this.id = id;
    this.alreadyHaveEvent = params.alreadyHaveEvent;
    this.receivedEvent = params.receivedEvent;
    this.eoseTimeout = params.eoseTimeout || relay.baseEoseTimeout;
    this.oneose = params.oneose;
    this.onclose = params.onclose;
    this.oninvalidevent = params.oninvalidevent;
    this.onevent = params.onevent || ((event) => {
      console.warn(
        `onevent() callback not defined for subscription '${this.id}' in relay ${this.relay.url}. event received:`,
        event
      );
    });
  }
  fire() {
    this.relay.send('["REQ","' + this.id + '",' + JSON.stringify(this.filters).substring(1));
    this.eoseTimeoutHandle = setTimeout(this.receivedEose.bind(this), this.eoseTimeout);
  }
  receivedEose() {
    if (this.eosed)
      return;
    clearTimeout(this.eoseTimeoutHandle);
    this.eosed = true;
    this.oneose?.();
  }
  close(reason = "closed by caller") {
    if (!this.closed && this.relay.connected) {
      try {
        this.relay.send('["CLOSE",' + JSON.stringify(this.id) + "]");
      } catch (err) {
        if (err instanceof SendingOnClosedConnection) {
        } else {
          throw err;
        }
      }
      this.closed = true;
    }
    this.relay.openSubs.delete(this.id);
    if (!this.id.startsWith("<forced-ping>")) {
      this.relay.ongoingOperations--;
      if (this.relay.ongoingOperations === 0) {
        this.relay.idleSince = Date.now();
        this.relay.scheduleIdleClose();
      }
    }
    this.onclose?.(reason);
  }
};
var M = 256;
var HLL_HEX_LENGTH = M * 2;
var utf8Encoder22 = new TextEncoder();
function getCountManyFilter(target, directive) {
  switch (directive) {
    case "reactions":
      return { "#e": [target], kinds: [7] };
    case "reposts":
      return { "#e": [target], kinds: [6] };
    case "quotes":
      return { "#q": [target], kinds: [1, 1111] };
    case "replies":
      return { "#e": [target], kinds: [1] };
    case "comments":
      return { "#E": [target], kinds: [1111] };
    case "followers":
      return { "#p": [target], kinds: [3] };
  }
}
function newHll() {
  return new Uint8Array(M);
}
function hllDecode(hex) {
  if (hex.length !== HLL_HEX_LENGTH || !/^[0-9a-f]+$/.test(hex))
    return void 0;
  const registers = new Uint8Array(M);
  for (let i22 = 0; i22 < M; i22++) {
    registers[i22] = parseInt(hex.slice(i22 * 2, i22 * 2 + 2), 16);
  }
  return registers;
}
function hllEncode(registers) {
  if (registers.length !== M)
    throw new Error(`invalid number of registers ${registers.length}`);
  let hex = "";
  for (let i22 = 0; i22 < M; i22++) {
    hex += registers[i22].toString(16).padStart(2, "0");
  }
  return hex;
}
function mergeHll(target, source) {
  if (target.length === 0)
    target = newHll();
  if (target.length !== M)
    throw new Error(`invalid number of registers ${target.length}`);
  if (source.length !== M)
    throw new Error(`invalid number of registers ${source.length}`);
  for (let i22 = 0; i22 < M; i22++) {
    if (source[i22] > target[i22])
      target[i22] = source[i22];
  }
  return target;
}
var AbstractSimplePool = class {
  relays = /* @__PURE__ */ new Map();
  seenOn = /* @__PURE__ */ new Map();
  trackRelays = false;
  verifyEvent;
  enablePing;
  enableReconnect;
  idleTimeout = 2e4;
  automaticallyAuth;
  onRelayConnectionFailure;
  onRelayConnectionSuccess;
  allowConnectingToRelay;
  maxWaitForConnection;
  _WebSocket;
  constructor(opts) {
    this.verifyEvent = opts.verifyEvent;
    this._WebSocket = opts.websocketImplementation;
    this.enablePing = opts.enablePing;
    this.enableReconnect = opts.enableReconnect || false;
    if (opts.idleTimeout)
      this.idleTimeout = opts.idleTimeout;
    this.automaticallyAuth = opts.automaticallyAuth;
    this.onRelayConnectionFailure = opts.onRelayConnectionFailure;
    this.onRelayConnectionSuccess = opts.onRelayConnectionSuccess;
    this.allowConnectingToRelay = opts.allowConnectingToRelay;
    this.maxWaitForConnection = opts.maxWaitForConnection || 3e3;
  }
  async ensureRelay(url, params) {
    url = normalizeURL(url);
    let relay = this.relays.get(url);
    if (!relay) {
      relay = new AbstractRelay(url, {
        verifyEvent: this.verifyEvent,
        websocketImplementation: this._WebSocket,
        enablePing: this.enablePing,
        enableReconnect: this.enableReconnect,
        idleTimeout: this.idleTimeout
      });
      relay.onclose = () => {
        this.relays.delete(url);
      };
      this.relays.set(url, relay);
    }
    if (this.automaticallyAuth) {
      const authSignerFn = this.automaticallyAuth(url);
      if (authSignerFn) {
        relay.onauth = authSignerFn;
      }
    }
    try {
      await relay.connect({
        timeout: params?.connectionTimeout,
        abort: params?.abort
      });
    } catch (err) {
      this.relays.delete(url);
      throw err;
    }
    return relay;
  }
  close(relays) {
    relays.map(normalizeURL).forEach((url) => {
      this.relays.get(url)?.close();
      this.relays.delete(url);
    });
  }
  subscribe(relays, filter, params) {
    const request = [];
    const uniqUrls = [];
    for (let i22 = 0; i22 < relays.length; i22++) {
      const url = normalizeURL(relays[i22]);
      if (!request.find((r) => r.url === url)) {
        if (uniqUrls.indexOf(url) === -1) {
          uniqUrls.push(url);
          request.push({ url, filter });
        }
      }
    }
    return this.subscribeMap(request, params);
  }
  subscribeMany(relays, filter, params) {
    return this.subscribe(relays, filter, params);
  }
  subscribeMap(requests, params) {
    const grouped = /* @__PURE__ */ new Map();
    for (const req of requests) {
      const { url, filter } = req;
      if (!grouped.has(url))
        grouped.set(url, []);
      grouped.get(url).push(filter);
    }
    const groupedRequests = Array.from(grouped.entries()).map(([url, filters2]) => ({ url, filters: filters2 }));
    if (this.trackRelays) {
      params.receivedEvent = (relay, id) => {
        let set = this.seenOn.get(id);
        if (!set) {
          set = /* @__PURE__ */ new Set();
          this.seenOn.set(id, set);
        }
        set.add(relay);
      };
    }
    const _knownIds = /* @__PURE__ */ new Set();
    const subs = [];
    const eosesReceived = [];
    let handleEose = (i22) => {
      if (eosesReceived[i22])
        return;
      eosesReceived[i22] = true;
      if (eosesReceived.filter((a) => a).length === groupedRequests.length) {
        params.oneose?.();
        handleEose = () => {
        };
      }
    };
    const closesReceived = [];
    let handleClose = (i22, url, reason) => {
      if (closesReceived[i22])
        return;
      handleEose(i22);
      closesReceived[i22] = { url, reason };
      if (closesReceived.filter((a) => a).length === groupedRequests.length) {
        params.onclose?.(closesReceived);
        handleClose = () => {
        };
      }
    };
    const localAlreadyHaveEventHandler = (id) => {
      if (params.alreadyHaveEvent?.(id)) {
        return true;
      }
      const have = _knownIds.has(id);
      _knownIds.add(id);
      return have;
    };
    const allOpened = Promise.all(
      groupedRequests.map(async ({ url, filters: filters2 }, i22) => {
        if (this.allowConnectingToRelay?.(url, ["read", filters2]) === false) {
          handleClose(i22, url, "connection skipped by allowConnectingToRelay");
          return;
        }
        let relay;
        try {
          relay = await this.ensureRelay(url, {
            connectionTimeout: this.maxWaitForConnection < (params.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
            abort: params.abort
          });
        } catch (err) {
          this.onRelayConnectionFailure?.(url);
          handleClose(i22, url, err?.message || String(err));
          return;
        }
        this.onRelayConnectionSuccess?.(url);
        let subscription = relay.subscribe(filters2, {
          ...params,
          oneose: () => handleEose(i22),
          onclose: (reason) => {
            if (reason.startsWith("auth-required: ") && params.onauth) {
              relay.auth(params.onauth).then(() => {
                relay.subscribe(filters2, {
                  ...params,
                  oneose: () => handleEose(i22),
                  onclose: (reason2) => {
                    handleClose(i22, url, reason2);
                  },
                  alreadyHaveEvent: localAlreadyHaveEventHandler,
                  eoseTimeout: params.maxWait,
                  abort: params.abort
                });
              }).catch((err) => {
                handleClose(i22, url, `auth was required and attempted, but failed with: ${err}`);
              });
            } else {
              handleClose(i22, url, reason);
            }
          },
          alreadyHaveEvent: localAlreadyHaveEventHandler,
          eoseTimeout: params.maxWait,
          abort: params.abort
        });
        subs.push(subscription);
      })
    );
    return {
      async close(reason) {
        await allOpened;
        subs.forEach((sub) => {
          sub.close(reason);
        });
      }
    };
  }
  subscribeEose(relays, filter, params) {
    let subcloser;
    subcloser = this.subscribe(relays, filter, {
      ...params,
      oneose() {
        const reason = "closed automatically on eose";
        if (subcloser)
          subcloser.close(reason);
        else
          params.onclose?.(relays.map((url) => ({ url, reason })));
      }
    });
    return subcloser;
  }
  subscribeManyEose(relays, filter, params) {
    return this.subscribeEose(relays, filter, params);
  }
  async querySync(relays, filter, params) {
    return new Promise(async (resolve) => {
      const events = [];
      this.subscribeEose(relays, filter, {
        ...params,
        onevent(event) {
          events.push(event);
        },
        onclose(_) {
          resolve(events);
        }
      });
    });
  }
  async get(relays, filter, params) {
    filter.limit = 1;
    const events = await this.querySync(relays, filter, params);
    events.sort((a, b) => b.created_at - a.created_at);
    return events[0] || null;
  }
  async countMany(relays, target, directive, params) {
    const filter = getCountManyFilter(target, directive);
    const urls = [];
    for (let i22 = 0; i22 < relays.length; i22++) {
      const url = normalizeURL(relays[i22]);
      if (urls.indexOf(url) === -1)
        urls.push(url);
    }
    const responses = await Promise.all(
      urls.map(async (url) => {
        if (this.allowConnectingToRelay?.(url, ["read", [filter]]) === false)
          return null;
        let relay;
        try {
          relay = await this.ensureRelay(url, {
            connectionTimeout: this.maxWaitForConnection < (params?.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
            abort: params?.abort
          });
        } catch (err) {
          this.onRelayConnectionFailure?.(url);
          return null;
        }
        this.onRelayConnectionSuccess?.(url);
        return relay.countWithHLL([filter], { id: params?.id }).catch(() => null);
      })
    );
    let count = 0;
    let hll;
    for (const response of responses) {
      if (!response)
        continue;
      if (response.count > count)
        count = response.count;
      if (!response.hll || response.hll.length !== 512)
        continue;
      const registers = hllDecode(response.hll);
      if (!registers)
        continue;
      hll = mergeHll(hll || new Uint8Array(0), registers);
    }
    return hll ? { count, hll: hllEncode(hll) } : { count };
  }
  publish(relays, event, params) {
    return relays.map(normalizeURL).map(async (url, i22, arr) => {
      if (arr.indexOf(url) !== i22) {
        return Promise.reject("duplicate url");
      }
      if (this.allowConnectingToRelay?.(url, ["write", event]) === false) {
        return Promise.reject("connection skipped by allowConnectingToRelay");
      }
      let r;
      try {
        r = await this.ensureRelay(url, {
          connectionTimeout: this.maxWaitForConnection < (params?.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
          abort: params?.abort
        });
      } catch (err) {
        this.onRelayConnectionFailure?.(url);
        return Promise.reject("connection failure: " + String(err));
      }
      return r.publish(event).catch(async (err) => {
        if (err instanceof Error && err.message.startsWith("auth-required: ") && params?.onauth) {
          await r.auth(params.onauth);
          return r.publish(event);
        }
        throw err;
      }).then((reason) => {
        if (this.trackRelays) {
          let set = this.seenOn.get(event.id);
          if (!set) {
            set = /* @__PURE__ */ new Set();
            this.seenOn.set(event.id, set);
          }
          set.add(r);
        }
        return reason;
      });
    });
  }
  listConnectionStatus() {
    const map = /* @__PURE__ */ new Map();
    this.relays.forEach((relay, url) => map.set(url, relay.connected));
    return map;
  }
  destroy() {
    this.relays.forEach((conn) => conn.close());
    this.relays = /* @__PURE__ */ new Map();
  }
  pruneIdleRelays(idleThresholdMs = 1e4) {
    const prunedUrls = [];
    for (const [url, relay] of this.relays) {
      if (relay.idleSince && Date.now() - relay.idleSince >= idleThresholdMs) {
        this.relays.delete(url);
        prunedUrls.push(url);
        relay.close();
      }
    }
    return prunedUrls;
  }
};
var _WebSocket;
try {
  _WebSocket = WebSocket;
} catch {
}
var SimplePool = class extends AbstractSimplePool {
  constructor(options) {
    super({ verifyEvent: verifyEvent2, websocketImplementation: _WebSocket, maxWaitForConnection: 3e3, ...options });
  }
};

// node_modules/@noble/ciphers/utils.js
function isBytes2(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array";
}
function abool2(b) {
  if (typeof b !== "boolean")
    throw new Error(`boolean expected, not ${b}`);
}
function anumber2(n) {
  if (!Number.isSafeInteger(n) || n < 0)
    throw new Error("positive integer expected, got " + n);
}
function abytes2(value, length, title = "") {
  const bytes = isBytes2(value);
  const len = value?.length;
  const needsLen = length !== void 0;
  if (!bytes || needsLen && len !== length) {
    const prefix = title && `"${title}" `;
    const ofLen = needsLen ? ` of length ${length}` : "";
    const got = bytes ? `length=${len}` : `type=${typeof value}`;
    throw new Error(prefix + "expected Uint8Array" + ofLen + ", got " + got);
  }
  return value;
}
function aexists2(instance, checkFinished = true) {
  if (instance.destroyed)
    throw new Error("Hash instance has been destroyed");
  if (checkFinished && instance.finished)
    throw new Error("Hash#digest() has already been called");
}
function aoutput2(out, instance) {
  abytes2(out, void 0, "output");
  const min = instance.outputLen;
  if (out.length < min) {
    throw new Error("digestInto() expects output buffer of length at least " + min);
  }
}
function u32(arr) {
  return new Uint32Array(arr.buffer, arr.byteOffset, Math.floor(arr.byteLength / 4));
}
function clean2(...arrays) {
  for (let i4 = 0; i4 < arrays.length; i4++) {
    arrays[i4].fill(0);
  }
}
function createView2(arr) {
  return new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
}
var isLE = /* @__PURE__ */ (() => new Uint8Array(new Uint32Array([287454020]).buffer)[0] === 68)();
function overlapBytes(a, b) {
  return a.buffer === b.buffer && // best we can do, may fail with an obscure Proxy
  a.byteOffset < b.byteOffset + b.byteLength && // a starts before b end
  b.byteOffset < a.byteOffset + a.byteLength;
}
function complexOverlapBytes(input, output) {
  if (overlapBytes(input, output) && input.byteOffset < output.byteOffset)
    throw new Error("complex overlap of input and output is not supported");
}
function checkOpts(defaults, opts) {
  if (opts == null || typeof opts !== "object")
    throw new Error("options must be defined");
  const merged = Object.assign(defaults, opts);
  return merged;
}
function equalBytes(a, b) {
  if (a.length !== b.length)
    return false;
  let diff = 0;
  for (let i4 = 0; i4 < a.length; i4++)
    diff |= a[i4] ^ b[i4];
  return diff === 0;
}
var wrapCipher = /* @__NO_SIDE_EFFECTS__ */ (params, constructor) => {
  function wrappedCipher(key, ...args) {
    abytes2(key, void 0, "key");
    if (!isLE)
      throw new Error("Non little-endian hardware is not yet supported");
    if (params.nonceLength !== void 0) {
      const nonce = args[0];
      abytes2(nonce, params.varSizeNonce ? void 0 : params.nonceLength, "nonce");
    }
    const tagl = params.tagLength;
    if (tagl && args[1] !== void 0)
      abytes2(args[1], void 0, "AAD");
    const cipher = constructor(key, ...args);
    const checkOutput = (fnLength, output) => {
      if (output !== void 0) {
        if (fnLength !== 2)
          throw new Error("cipher output not supported");
        abytes2(output, void 0, "output");
      }
    };
    let called = false;
    const wrCipher = {
      encrypt(data, output) {
        if (called)
          throw new Error("cannot encrypt() twice with same key + nonce");
        called = true;
        abytes2(data);
        checkOutput(cipher.encrypt.length, output);
        return cipher.encrypt(data, output);
      },
      decrypt(data, output) {
        abytes2(data);
        if (tagl && data.length < tagl)
          throw new Error('"ciphertext" expected length bigger than tagLength=' + tagl);
        checkOutput(cipher.decrypt.length, output);
        return cipher.decrypt(data, output);
      }
    };
    return wrCipher;
  }
  Object.assign(wrappedCipher, params);
  return wrappedCipher;
};
function getOutput(expectedLength, out, onlyAligned = true) {
  if (out === void 0)
    return new Uint8Array(expectedLength);
  if (out.length !== expectedLength)
    throw new Error('"output" expected Uint8Array of length ' + expectedLength + ", got: " + out.length);
  if (onlyAligned && !isAligned32(out))
    throw new Error("invalid output, must be aligned");
  return out;
}
function u64Lengths(dataLength, aadLength, isLE2) {
  abool2(isLE2);
  const num2 = new Uint8Array(16);
  const view = createView2(num2);
  view.setBigUint64(0, BigInt(aadLength), isLE2);
  view.setBigUint64(8, BigInt(dataLength), isLE2);
  return num2;
}
function isAligned32(bytes) {
  return bytes.byteOffset % 4 === 0;
}
function copyBytes2(bytes) {
  return Uint8Array.from(bytes);
}

// node_modules/@noble/ciphers/aes.js
var BLOCK_SIZE = 16;
var POLY = 283;
function validateKeyLength(key) {
  if (![16, 24, 32].includes(key.length))
    throw new Error('"aes key" expected Uint8Array of length 16/24/32, got length=' + key.length);
}
function mul2(n) {
  return n << 1 ^ POLY & -(n >> 7);
}
function mul(a, b) {
  let res = 0;
  for (; b > 0; b >>= 1) {
    res ^= a & -(b & 1);
    a = mul2(a);
  }
  return res;
}
var sbox = /* @__PURE__ */ (() => {
  const t = new Uint8Array(256);
  for (let i4 = 0, x = 1; i4 < 256; i4++, x ^= mul2(x))
    t[i4] = x;
  const box = new Uint8Array(256);
  box[0] = 99;
  for (let i4 = 0; i4 < 255; i4++) {
    let x = t[255 - i4];
    x |= x << 8;
    box[t[i4]] = (x ^ x >> 4 ^ x >> 5 ^ x >> 6 ^ x >> 7 ^ 99) & 255;
  }
  clean2(t);
  return box;
})();
var invSbox = /* @__PURE__ */ sbox.map((_, j) => sbox.indexOf(j));
var rotr32_8 = (n) => n << 24 | n >>> 8;
var rotl32_8 = (n) => n << 8 | n >>> 24;
function genTtable(sbox2, fn) {
  if (sbox2.length !== 256)
    throw new Error("Wrong sbox length");
  const T0 = new Uint32Array(256).map((_, j) => fn(sbox2[j]));
  const T1 = T0.map(rotl32_8);
  const T2 = T1.map(rotl32_8);
  const T3 = T2.map(rotl32_8);
  const T01 = new Uint32Array(256 * 256);
  const T23 = new Uint32Array(256 * 256);
  const sbox22 = new Uint16Array(256 * 256);
  for (let i4 = 0; i4 < 256; i4++) {
    for (let j = 0; j < 256; j++) {
      const idx = i4 * 256 + j;
      T01[idx] = T0[i4] ^ T1[j];
      T23[idx] = T2[i4] ^ T3[j];
      sbox22[idx] = sbox2[i4] << 8 | sbox2[j];
    }
  }
  return { sbox: sbox2, sbox2: sbox22, T0, T1, T2, T3, T01, T23 };
}
var tableEncoding = /* @__PURE__ */ genTtable(sbox, (s) => mul(s, 3) << 24 | s << 16 | s << 8 | mul(s, 2));
var tableDecoding = /* @__PURE__ */ genTtable(invSbox, (s) => mul(s, 11) << 24 | mul(s, 13) << 16 | mul(s, 9) << 8 | mul(s, 14));
var xPowers = /* @__PURE__ */ (() => {
  const p = new Uint8Array(16);
  for (let i4 = 0, x = 1; i4 < 16; i4++, x = mul2(x))
    p[i4] = x;
  return p;
})();
function expandKeyLE(key) {
  abytes2(key);
  const len = key.length;
  validateKeyLength(key);
  const { sbox2 } = tableEncoding;
  const toClean = [];
  if (!isAligned32(key))
    toClean.push(key = copyBytes2(key));
  const k32 = u32(key);
  const Nk = k32.length;
  const subByte = (n) => applySbox(sbox2, n, n, n, n);
  const xk = new Uint32Array(len + 28);
  xk.set(k32);
  for (let i4 = Nk; i4 < xk.length; i4++) {
    let t = xk[i4 - 1];
    if (i4 % Nk === 0)
      t = subByte(rotr32_8(t)) ^ xPowers[i4 / Nk - 1];
    else if (Nk > 6 && i4 % Nk === 4)
      t = subByte(t);
    xk[i4] = xk[i4 - Nk] ^ t;
  }
  clean2(...toClean);
  return xk;
}
function expandKeyDecLE(key) {
  const encKey = expandKeyLE(key);
  const xk = encKey.slice();
  const Nk = encKey.length;
  const { sbox2 } = tableEncoding;
  const { T0, T1, T2, T3 } = tableDecoding;
  for (let i4 = 0; i4 < Nk; i4 += 4) {
    for (let j = 0; j < 4; j++)
      xk[i4 + j] = encKey[Nk - i4 - 4 + j];
  }
  clean2(encKey);
  for (let i4 = 4; i4 < Nk - 4; i4++) {
    const x = xk[i4];
    const w = applySbox(sbox2, x, x, x, x);
    xk[i4] = T0[w & 255] ^ T1[w >>> 8 & 255] ^ T2[w >>> 16 & 255] ^ T3[w >>> 24];
  }
  return xk;
}
function apply0123(T01, T23, s0, s1, s2, s3) {
  return T01[s0 << 8 & 65280 | s1 >>> 8 & 255] ^ T23[s2 >>> 8 & 65280 | s3 >>> 24 & 255];
}
function applySbox(sbox2, s0, s1, s2, s3) {
  return sbox2[s0 & 255 | s1 & 65280] | sbox2[s2 >>> 16 & 255 | s3 >>> 16 & 65280] << 16;
}
function encrypt(xk, s0, s1, s2, s3) {
  const { sbox2, T01, T23 } = tableEncoding;
  let k = 0;
  s0 ^= xk[k++], s1 ^= xk[k++], s2 ^= xk[k++], s3 ^= xk[k++];
  const rounds = xk.length / 4 - 2;
  for (let i4 = 0; i4 < rounds; i4++) {
    const t02 = xk[k++] ^ apply0123(T01, T23, s0, s1, s2, s3);
    const t12 = xk[k++] ^ apply0123(T01, T23, s1, s2, s3, s0);
    const t22 = xk[k++] ^ apply0123(T01, T23, s2, s3, s0, s1);
    const t32 = xk[k++] ^ apply0123(T01, T23, s3, s0, s1, s2);
    s0 = t02, s1 = t12, s2 = t22, s3 = t32;
  }
  const t0 = xk[k++] ^ applySbox(sbox2, s0, s1, s2, s3);
  const t1 = xk[k++] ^ applySbox(sbox2, s1, s2, s3, s0);
  const t2 = xk[k++] ^ applySbox(sbox2, s2, s3, s0, s1);
  const t3 = xk[k++] ^ applySbox(sbox2, s3, s0, s1, s2);
  return { s0: t0, s1: t1, s2: t2, s3: t3 };
}
function decrypt(xk, s0, s1, s2, s3) {
  const { sbox2, T01, T23 } = tableDecoding;
  let k = 0;
  s0 ^= xk[k++], s1 ^= xk[k++], s2 ^= xk[k++], s3 ^= xk[k++];
  const rounds = xk.length / 4 - 2;
  for (let i4 = 0; i4 < rounds; i4++) {
    const t02 = xk[k++] ^ apply0123(T01, T23, s0, s3, s2, s1);
    const t12 = xk[k++] ^ apply0123(T01, T23, s1, s0, s3, s2);
    const t22 = xk[k++] ^ apply0123(T01, T23, s2, s1, s0, s3);
    const t32 = xk[k++] ^ apply0123(T01, T23, s3, s2, s1, s0);
    s0 = t02, s1 = t12, s2 = t22, s3 = t32;
  }
  const t0 = xk[k++] ^ applySbox(sbox2, s0, s3, s2, s1);
  const t1 = xk[k++] ^ applySbox(sbox2, s1, s0, s3, s2);
  const t2 = xk[k++] ^ applySbox(sbox2, s2, s1, s0, s3);
  const t3 = xk[k++] ^ applySbox(sbox2, s3, s2, s1, s0);
  return { s0: t0, s1: t1, s2: t2, s3: t3 };
}
function validateBlockDecrypt(data) {
  abytes2(data);
  if (data.length % BLOCK_SIZE !== 0) {
    throw new Error("aes-(cbc/ecb).decrypt ciphertext should consist of blocks with size " + BLOCK_SIZE);
  }
}
function validateBlockEncrypt(plaintext, pcks5, dst) {
  abytes2(plaintext);
  let outLen = plaintext.length;
  const remaining = outLen % BLOCK_SIZE;
  if (!pcks5 && remaining !== 0)
    throw new Error("aec/(cbc-ecb): unpadded plaintext with disabled padding");
  if (!isAligned32(plaintext))
    plaintext = copyBytes2(plaintext);
  const b = u32(plaintext);
  if (pcks5) {
    let left = BLOCK_SIZE - remaining;
    if (!left)
      left = BLOCK_SIZE;
    outLen = outLen + left;
  }
  dst = getOutput(outLen, dst);
  complexOverlapBytes(plaintext, dst);
  const o = u32(dst);
  return { b, o, out: dst };
}
function validatePCKS(data, pcks5) {
  if (!pcks5)
    return data;
  const len = data.length;
  if (!len)
    throw new Error("aes/pcks5: empty ciphertext not allowed");
  const lastByte = data[len - 1];
  if (lastByte <= 0 || lastByte > 16)
    throw new Error("aes/pcks5: wrong padding");
  const out = data.subarray(0, -lastByte);
  for (let i4 = 0; i4 < lastByte; i4++)
    if (data[len - i4 - 1] !== lastByte)
      throw new Error("aes/pcks5: wrong padding");
  return out;
}
function padPCKS(left) {
  const tmp = new Uint8Array(16);
  const tmp32 = u32(tmp);
  tmp.set(left);
  const paddingByte = BLOCK_SIZE - left.length;
  for (let i4 = BLOCK_SIZE - paddingByte; i4 < BLOCK_SIZE; i4++)
    tmp[i4] = paddingByte;
  return tmp32;
}
var cbc = /* @__PURE__ */ wrapCipher({ blockSize: 16, nonceLength: 16 }, function aescbc(key, iv, opts = {}) {
  const pcks5 = !opts.disablePadding;
  return {
    encrypt(plaintext, dst) {
      const xk = expandKeyLE(key);
      const { b, o, out: _out } = validateBlockEncrypt(plaintext, pcks5, dst);
      let _iv = iv;
      const toClean = [xk];
      if (!isAligned32(_iv))
        toClean.push(_iv = copyBytes2(_iv));
      const n32 = u32(_iv);
      let s0 = n32[0], s1 = n32[1], s2 = n32[2], s3 = n32[3];
      let i4 = 0;
      for (; i4 + 4 <= b.length; ) {
        s0 ^= b[i4 + 0], s1 ^= b[i4 + 1], s2 ^= b[i4 + 2], s3 ^= b[i4 + 3];
        ({ s0, s1, s2, s3 } = encrypt(xk, s0, s1, s2, s3));
        o[i4++] = s0, o[i4++] = s1, o[i4++] = s2, o[i4++] = s3;
      }
      if (pcks5) {
        const tmp32 = padPCKS(plaintext.subarray(i4 * 4));
        s0 ^= tmp32[0], s1 ^= tmp32[1], s2 ^= tmp32[2], s3 ^= tmp32[3];
        ({ s0, s1, s2, s3 } = encrypt(xk, s0, s1, s2, s3));
        o[i4++] = s0, o[i4++] = s1, o[i4++] = s2, o[i4++] = s3;
      }
      clean2(...toClean);
      return _out;
    },
    decrypt(ciphertext, dst) {
      validateBlockDecrypt(ciphertext);
      const xk = expandKeyDecLE(key);
      let _iv = iv;
      const toClean = [xk];
      if (!isAligned32(_iv))
        toClean.push(_iv = copyBytes2(_iv));
      const n32 = u32(_iv);
      dst = getOutput(ciphertext.length, dst);
      if (!isAligned32(ciphertext))
        toClean.push(ciphertext = copyBytes2(ciphertext));
      complexOverlapBytes(ciphertext, dst);
      const b = u32(ciphertext);
      const o = u32(dst);
      let s0 = n32[0], s1 = n32[1], s2 = n32[2], s3 = n32[3];
      for (let i4 = 0; i4 + 4 <= b.length; ) {
        const ps0 = s0, ps1 = s1, ps2 = s2, ps3 = s3;
        s0 = b[i4 + 0], s1 = b[i4 + 1], s2 = b[i4 + 2], s3 = b[i4 + 3];
        const { s0: o0, s1: o1, s2: o2, s3: o3 } = decrypt(xk, s0, s1, s2, s3);
        o[i4++] = o0 ^ ps0, o[i4++] = o1 ^ ps1, o[i4++] = o2 ^ ps2, o[i4++] = o3 ^ ps3;
      }
      clean2(...toClean);
      return validatePCKS(dst, pcks5);
    }
  };
});
function isBytes32(a) {
  return a instanceof Uint32Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint32Array";
}
function encryptBlock(xk, block) {
  abytes2(block, 16, "block");
  if (!isBytes32(xk))
    throw new Error("_encryptBlock accepts result of expandKeyLE");
  const b32 = u32(block);
  let { s0, s1, s2, s3 } = encrypt(xk, b32[0], b32[1], b32[2], b32[3]);
  b32[0] = s0, b32[1] = s1, b32[2] = s2, b32[3] = s3;
  return block;
}
function dbl(block) {
  let carry = 0;
  for (let i4 = BLOCK_SIZE - 1; i4 >= 0; i4--) {
    const newCarry = (block[i4] & 128) >>> 7;
    block[i4] = block[i4] << 1 | carry;
    carry = newCarry;
  }
  if (carry) {
    block[BLOCK_SIZE - 1] ^= 135;
  }
  return block;
}
function xorBlock(a, b) {
  if (a.length !== b.length)
    throw new Error("xorBlock: blocks must have same length");
  for (let i4 = 0; i4 < a.length; i4++) {
    a[i4] = a[i4] ^ b[i4];
  }
  return a;
}
var _CMAC = class {
  buffer;
  destroyed;
  k1;
  k2;
  xk;
  constructor(key) {
    abytes2(key);
    validateKeyLength(key);
    this.xk = expandKeyLE(key);
    this.buffer = new Uint8Array(0);
    this.destroyed = false;
    const L = new Uint8Array(BLOCK_SIZE);
    encryptBlock(this.xk, L);
    this.k1 = dbl(L);
    this.k2 = dbl(new Uint8Array(this.k1));
  }
  update(data) {
    const { destroyed, buffer } = this;
    if (destroyed)
      throw new Error("CMAC instance was destroyed");
    abytes2(data);
    const newBuffer = new Uint8Array(buffer.length + data.length);
    newBuffer.set(buffer);
    newBuffer.set(data, buffer.length);
    this.buffer = newBuffer;
    return this;
  }
  // see https://www.rfc-editor.org/rfc/rfc4493.html#section-2.4
  digest() {
    if (this.destroyed)
      throw new Error("CMAC instance was destroyed");
    const { buffer } = this;
    const msgLen = buffer.length;
    let n = Math.ceil(msgLen / BLOCK_SIZE);
    let flag;
    if (n === 0) {
      n = 1;
      flag = false;
    } else {
      flag = msgLen % BLOCK_SIZE === 0;
    }
    const lastBlockStart = (n - 1) * BLOCK_SIZE;
    const lastBlockData = buffer.subarray(lastBlockStart);
    let m_last;
    if (flag) {
      m_last = xorBlock(new Uint8Array(lastBlockData), this.k1);
    } else {
      const padded = new Uint8Array(BLOCK_SIZE);
      padded.set(lastBlockData);
      padded[lastBlockData.length] = 128;
      m_last = xorBlock(padded, this.k2);
    }
    let x = new Uint8Array(BLOCK_SIZE);
    for (let i4 = 0; i4 < n - 1; i4++) {
      const m_i = buffer.subarray(i4 * BLOCK_SIZE, (i4 + 1) * BLOCK_SIZE);
      xorBlock(x, m_i);
      encryptBlock(this.xk, x);
    }
    xorBlock(x, m_last);
    encryptBlock(this.xk, x);
    clean2(m_last);
    return x;
  }
  destroy() {
    const { buffer, destroyed, xk, k1, k2 } = this;
    if (destroyed)
      return;
    this.destroyed = true;
    clean2(buffer, xk, k1, k2);
  }
};
var cmac = (key, message) => new _CMAC(key).update(message).digest();
cmac.create = (key) => new _CMAC(key);

// node_modules/@scure/base/index.js
function isBytes3(a) {
  return a instanceof Uint8Array || ArrayBuffer.isView(a) && a.constructor.name === "Uint8Array";
}
function abytes3(b) {
  if (!isBytes3(b))
    throw new Error("Uint8Array expected");
}
function isArrayOf(isString, arr) {
  if (!Array.isArray(arr))
    return false;
  if (arr.length === 0)
    return true;
  if (isString) {
    return arr.every((item) => typeof item === "string");
  } else {
    return arr.every((item) => Number.isSafeInteger(item));
  }
}
function afn(input) {
  if (typeof input !== "function")
    throw new Error("function expected");
  return true;
}
function astr(label, input) {
  if (typeof input !== "string")
    throw new Error(`${label}: string expected`);
  return true;
}
function anumber3(n) {
  if (!Number.isSafeInteger(n))
    throw new Error(`invalid integer: ${n}`);
}
function aArr(input) {
  if (!Array.isArray(input))
    throw new Error("array expected");
}
function astrArr(label, input) {
  if (!isArrayOf(true, input))
    throw new Error(`${label}: array of strings expected`);
}
function anumArr(label, input) {
  if (!isArrayOf(false, input))
    throw new Error(`${label}: array of numbers expected`);
}
// @__NO_SIDE_EFFECTS__
function chain(...args) {
  const id = (a) => a;
  const wrap = (a, b) => (c) => a(b(c));
  const encode = args.map((x) => x.encode).reduceRight(wrap, id);
  const decode2 = args.map((x) => x.decode).reduce(wrap, id);
  return { encode, decode: decode2 };
}
// @__NO_SIDE_EFFECTS__
function alphabet(letters) {
  const lettersA = typeof letters === "string" ? letters.split("") : letters;
  const len = lettersA.length;
  astrArr("alphabet", lettersA);
  const indexes = new Map(lettersA.map((l, i4) => [l, i4]));
  return {
    encode: (digits) => {
      aArr(digits);
      return digits.map((i4) => {
        if (!Number.isSafeInteger(i4) || i4 < 0 || i4 >= len)
          throw new Error(`alphabet.encode: digit index outside alphabet "${i4}". Allowed: ${letters}`);
        return lettersA[i4];
      });
    },
    decode: (input) => {
      aArr(input);
      return input.map((letter) => {
        astr("alphabet.decode", letter);
        const i4 = indexes.get(letter);
        if (i4 === void 0)
          throw new Error(`Unknown letter: "${letter}". Allowed: ${letters}`);
        return i4;
      });
    }
  };
}
// @__NO_SIDE_EFFECTS__
function join(separator = "") {
  astr("join", separator);
  return {
    encode: (from) => {
      astrArr("join.decode", from);
      return from.join(separator);
    },
    decode: (to) => {
      astr("join.decode", to);
      return to.split(separator);
    }
  };
}
// @__NO_SIDE_EFFECTS__
function padding(bits, chr = "=") {
  anumber3(bits);
  astr("padding", chr);
  return {
    encode(data) {
      astrArr("padding.encode", data);
      while (data.length * bits % 8)
        data.push(chr);
      return data;
    },
    decode(input) {
      astrArr("padding.decode", input);
      let end = input.length;
      if (end * bits % 8)
        throw new Error("padding: invalid, string should have whole number of bytes");
      for (; end > 0 && input[end - 1] === chr; end--) {
        const last = end - 1;
        const byte = last * bits;
        if (byte % 8 === 0)
          throw new Error("padding: invalid, string has too much padding");
      }
      return input.slice(0, end);
    }
  };
}
var gcd = (a, b) => b === 0 ? a : gcd(b, a % b);
var radix2carry = /* @__NO_SIDE_EFFECTS__ */ (from, to) => from + (to - gcd(from, to));
var powers = /* @__PURE__ */ (() => {
  let res = [];
  for (let i4 = 0; i4 < 40; i4++)
    res.push(2 ** i4);
  return res;
})();
function convertRadix2(data, from, to, padding2) {
  aArr(data);
  if (from <= 0 || from > 32)
    throw new Error(`convertRadix2: wrong from=${from}`);
  if (to <= 0 || to > 32)
    throw new Error(`convertRadix2: wrong to=${to}`);
  if (/* @__PURE__ */ radix2carry(from, to) > 32) {
    throw new Error(`convertRadix2: carry overflow from=${from} to=${to} carryBits=${/* @__PURE__ */ radix2carry(from, to)}`);
  }
  let carry = 0;
  let pos = 0;
  const max = powers[from];
  const mask = powers[to] - 1;
  const res = [];
  for (const n of data) {
    anumber3(n);
    if (n >= max)
      throw new Error(`convertRadix2: invalid data word=${n} from=${from}`);
    carry = carry << from | n;
    if (pos + from > 32)
      throw new Error(`convertRadix2: carry overflow pos=${pos} from=${from}`);
    pos += from;
    for (; pos >= to; pos -= to)
      res.push((carry >> pos - to & mask) >>> 0);
    const pow = powers[pos];
    if (pow === void 0)
      throw new Error("invalid carry");
    carry &= pow - 1;
  }
  carry = carry << to - pos & mask;
  if (!padding2 && pos >= from)
    throw new Error("Excess padding");
  if (!padding2 && carry > 0)
    throw new Error(`Non-zero padding: ${carry}`);
  if (padding2 && pos > 0)
    res.push(carry >>> 0);
  return res;
}
// @__NO_SIDE_EFFECTS__
function radix2(bits, revPadding = false) {
  anumber3(bits);
  if (bits <= 0 || bits > 32)
    throw new Error("radix2: bits should be in (0..32]");
  if (/* @__PURE__ */ radix2carry(8, bits) > 32 || /* @__PURE__ */ radix2carry(bits, 8) > 32)
    throw new Error("radix2: carry overflow");
  return {
    encode: (bytes) => {
      if (!isBytes3(bytes))
        throw new Error("radix2.encode input should be Uint8Array");
      return convertRadix2(Array.from(bytes), 8, bits, !revPadding);
    },
    decode: (digits) => {
      anumArr("radix2.decode", digits);
      return Uint8Array.from(convertRadix2(digits, bits, 8, revPadding));
    }
  };
}
function unsafeWrapper(fn) {
  afn(fn);
  return function(...args) {
    try {
      return fn.apply(null, args);
    } catch (e) {
    }
  };
}
var hasBase64Builtin = /* @__PURE__ */ (() => typeof Uint8Array.from([]).toBase64 === "function" && typeof Uint8Array.fromBase64 === "function")();
var decodeBase64Builtin = (s, isUrl) => {
  astr("base64", s);
  const re = isUrl ? /^[A-Za-z0-9=_-]+$/ : /^[A-Za-z0-9=+/]+$/;
  const alphabet2 = isUrl ? "base64url" : "base64";
  if (s.length > 0 && !re.test(s))
    throw new Error("invalid base64");
  return Uint8Array.fromBase64(s, { alphabet: alphabet2, lastChunkHandling: "strict" });
};
var base64 = hasBase64Builtin ? {
  encode(b) {
    abytes3(b);
    return b.toBase64();
  },
  decode(s) {
    return decodeBase64Builtin(s, false);
  }
} : /* @__PURE__ */ chain(/* @__PURE__ */ radix2(6), /* @__PURE__ */ alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"), /* @__PURE__ */ padding(6), /* @__PURE__ */ join(""));
var BECH_ALPHABET = /* @__PURE__ */ chain(/* @__PURE__ */ alphabet("qpzry9x8gf2tvdw0s3jn54khce6mua7l"), /* @__PURE__ */ join(""));
var POLYMOD_GENERATORS = [996825010, 642813549, 513874426, 1027748829, 705979059];
function bech32Polymod(pre) {
  const b = pre >> 25;
  let chk = (pre & 33554431) << 5;
  for (let i4 = 0; i4 < POLYMOD_GENERATORS.length; i4++) {
    if ((b >> i4 & 1) === 1)
      chk ^= POLYMOD_GENERATORS[i4];
  }
  return chk;
}
function bechChecksum(prefix, words, encodingConst = 1) {
  const len = prefix.length;
  let chk = 1;
  for (let i4 = 0; i4 < len; i4++) {
    const c = prefix.charCodeAt(i4);
    if (c < 33 || c > 126)
      throw new Error(`Invalid prefix (${prefix})`);
    chk = bech32Polymod(chk) ^ c >> 5;
  }
  chk = bech32Polymod(chk);
  for (let i4 = 0; i4 < len; i4++)
    chk = bech32Polymod(chk) ^ prefix.charCodeAt(i4) & 31;
  for (let v of words)
    chk = bech32Polymod(chk) ^ v;
  for (let i4 = 0; i4 < 6; i4++)
    chk = bech32Polymod(chk);
  chk ^= encodingConst;
  return BECH_ALPHABET.encode(convertRadix2([chk % powers[30]], 30, 5, false));
}
// @__NO_SIDE_EFFECTS__
function genBech32(encoding) {
  const ENCODING_CONST = encoding === "bech32" ? 1 : 734539939;
  const _words = /* @__PURE__ */ radix2(5);
  const fromWords = _words.decode;
  const toWords = _words.encode;
  const fromWordsUnsafe = unsafeWrapper(fromWords);
  function encode(prefix, words, limit = 90) {
    astr("bech32.encode prefix", prefix);
    if (isBytes3(words))
      words = Array.from(words);
    anumArr("bech32.encode", words);
    const plen = prefix.length;
    if (plen === 0)
      throw new TypeError(`Invalid prefix length ${plen}`);
    const actualLength = plen + 7 + words.length;
    if (limit !== false && actualLength > limit)
      throw new TypeError(`Length ${actualLength} exceeds limit ${limit}`);
    const lowered = prefix.toLowerCase();
    const sum = bechChecksum(lowered, words, ENCODING_CONST);
    return `${lowered}1${BECH_ALPHABET.encode(words)}${sum}`;
  }
  function decode2(str, limit = 90) {
    astr("bech32.decode input", str);
    const slen = str.length;
    if (slen < 8 || limit !== false && slen > limit)
      throw new TypeError(`invalid string length: ${slen} (${str}). Expected (8..${limit})`);
    const lowered = str.toLowerCase();
    if (str !== lowered && str !== str.toUpperCase())
      throw new Error(`String must be lowercase or uppercase`);
    const sepIndex = lowered.lastIndexOf("1");
    if (sepIndex === 0 || sepIndex === -1)
      throw new Error(`Letter "1" must be present between prefix and data only`);
    const prefix = lowered.slice(0, sepIndex);
    const data = lowered.slice(sepIndex + 1);
    if (data.length < 6)
      throw new Error("Data must be at least 6 characters long");
    const words = BECH_ALPHABET.decode(data).slice(0, -6);
    const sum = bechChecksum(prefix, words, ENCODING_CONST);
    if (!data.endsWith(sum))
      throw new Error(`Invalid checksum in ${str}: expected "${sum}"`);
    return { prefix, words };
  }
  const decodeUnsafe = unsafeWrapper(decode2);
  function decodeToBytes(str) {
    const { prefix, words } = decode2(str, false);
    return { prefix, words, bytes: fromWords(words) };
  }
  function encodeFromBytes(prefix, bytes) {
    return encode(prefix, toWords(bytes));
  }
  return {
    encode,
    decode: decode2,
    encodeFromBytes,
    decodeToBytes,
    decodeUnsafe,
    fromWords,
    fromWordsUnsafe,
    toWords
  };
}
var bech32 = /* @__PURE__ */ genBech32("bech32");

// node_modules/nostr-tools/lib/esm/nip04.js
var utf8Decoder3 = new TextDecoder("utf-8");
var utf8Encoder3 = new TextEncoder();
function encrypt2(secretKey, pubkey, text) {
  const privkey = secretKey instanceof Uint8Array ? secretKey : hexToBytes(secretKey);
  const key = secp256k1.getSharedSecret(privkey, hexToBytes("02" + pubkey));
  const normalizedKey = getNormalizedX(key);
  let iv = Uint8Array.from(randomBytes(16));
  let plaintext = utf8Encoder3.encode(text);
  let ciphertext = cbc(normalizedKey, iv).encrypt(plaintext);
  let ctb64 = base64.encode(new Uint8Array(ciphertext));
  let ivb64 = base64.encode(new Uint8Array(iv.buffer));
  return `${ctb64}?iv=${ivb64}`;
}
function decrypt2(secretKey, pubkey, data) {
  const privkey = secretKey instanceof Uint8Array ? secretKey : hexToBytes(secretKey);
  let [ctb64, ivb64] = data.split("?iv=");
  let key = secp256k1.getSharedSecret(privkey, hexToBytes("02" + pubkey));
  let normalizedKey = getNormalizedX(key);
  let iv = base64.decode(ivb64);
  let ciphertext = base64.decode(ctb64);
  let plaintext = cbc(normalizedKey, iv).decrypt(ciphertext);
  return utf8Decoder3.decode(plaintext);
}
function getNormalizedX(key) {
  return key.slice(1, 33);
}

// node_modules/@noble/ciphers/_arx.js
var encodeStr = (str) => Uint8Array.from(str.split(""), (c) => c.charCodeAt(0));
var sigma16 = encodeStr("expand 16-byte k");
var sigma32 = encodeStr("expand 32-byte k");
var sigma16_32 = u32(sigma16);
var sigma32_32 = u32(sigma32);
function rotl(a, b) {
  return a << b | a >>> 32 - b;
}
function isAligned322(b) {
  return b.byteOffset % 4 === 0;
}
var BLOCK_LEN = 64;
var BLOCK_LEN32 = 16;
var MAX_COUNTER = 2 ** 32 - 1;
var U32_EMPTY = Uint32Array.of();
function runCipher(core, sigma, key, nonce, data, output, counter, rounds) {
  const len = data.length;
  const block = new Uint8Array(BLOCK_LEN);
  const b32 = u32(block);
  const isAligned = isAligned322(data) && isAligned322(output);
  const d32 = isAligned ? u32(data) : U32_EMPTY;
  const o32 = isAligned ? u32(output) : U32_EMPTY;
  for (let pos = 0; pos < len; counter++) {
    core(sigma, key, nonce, b32, counter, rounds);
    if (counter >= MAX_COUNTER)
      throw new Error("arx: counter overflow");
    const take = Math.min(BLOCK_LEN, len - pos);
    if (isAligned && take === BLOCK_LEN) {
      const pos32 = pos / 4;
      if (pos % 4 !== 0)
        throw new Error("arx: invalid block position");
      for (let j = 0, posj; j < BLOCK_LEN32; j++) {
        posj = pos32 + j;
        o32[posj] = d32[posj] ^ b32[j];
      }
      pos += BLOCK_LEN;
      continue;
    }
    for (let j = 0, posj; j < take; j++) {
      posj = pos + j;
      output[posj] = data[posj] ^ block[j];
    }
    pos += take;
  }
}
function createCipher(core, opts) {
  const { allowShortKeys, extendNonceFn, counterLength, counterRight, rounds } = checkOpts({ allowShortKeys: false, counterLength: 8, counterRight: false, rounds: 20 }, opts);
  if (typeof core !== "function")
    throw new Error("core must be a function");
  anumber2(counterLength);
  anumber2(rounds);
  abool2(counterRight);
  abool2(allowShortKeys);
  return (key, nonce, data, output, counter = 0) => {
    abytes2(key, void 0, "key");
    abytes2(nonce, void 0, "nonce");
    abytes2(data, void 0, "data");
    const len = data.length;
    if (output === void 0)
      output = new Uint8Array(len);
    abytes2(output, void 0, "output");
    anumber2(counter);
    if (counter < 0 || counter >= MAX_COUNTER)
      throw new Error("arx: counter overflow");
    if (output.length < len)
      throw new Error(`arx: output (${output.length}) is shorter than data (${len})`);
    const toClean = [];
    let l = key.length;
    let k;
    let sigma;
    if (l === 32) {
      toClean.push(k = copyBytes2(key));
      sigma = sigma32_32;
    } else if (l === 16 && allowShortKeys) {
      k = new Uint8Array(32);
      k.set(key);
      k.set(key, 16);
      sigma = sigma16_32;
      toClean.push(k);
    } else {
      abytes2(key, 32, "arx key");
      throw new Error("invalid key size");
    }
    if (!isAligned322(nonce))
      toClean.push(nonce = copyBytes2(nonce));
    const k32 = u32(k);
    if (extendNonceFn) {
      if (nonce.length !== 24)
        throw new Error(`arx: extended nonce must be 24 bytes`);
      extendNonceFn(sigma, k32, u32(nonce.subarray(0, 16)), k32);
      nonce = nonce.subarray(16);
    }
    const nonceNcLen = 16 - counterLength;
    if (nonceNcLen !== nonce.length)
      throw new Error(`arx: nonce must be ${nonceNcLen} or 16 bytes`);
    if (nonceNcLen !== 12) {
      const nc = new Uint8Array(12);
      nc.set(nonce, counterRight ? 0 : 12 - nonce.length);
      nonce = nc;
      toClean.push(nonce);
    }
    const n32 = u32(nonce);
    runCipher(core, sigma, k32, n32, data, output, counter, rounds);
    clean2(...toClean);
    return output;
  };
}

// node_modules/@noble/ciphers/_poly1305.js
function u8to16(a, i4) {
  return a[i4++] & 255 | (a[i4++] & 255) << 8;
}
var Poly1305 = class {
  blockLen = 16;
  outputLen = 16;
  buffer = new Uint8Array(16);
  r = new Uint16Array(10);
  // Allocating 1 array with .subarray() here is slower than 3
  h = new Uint16Array(10);
  pad = new Uint16Array(8);
  pos = 0;
  finished = false;
  // Can be speed-up using BigUint64Array, at the cost of complexity
  constructor(key) {
    key = copyBytes2(abytes2(key, 32, "key"));
    const t0 = u8to16(key, 0);
    const t1 = u8to16(key, 2);
    const t2 = u8to16(key, 4);
    const t3 = u8to16(key, 6);
    const t4 = u8to16(key, 8);
    const t5 = u8to16(key, 10);
    const t6 = u8to16(key, 12);
    const t7 = u8to16(key, 14);
    this.r[0] = t0 & 8191;
    this.r[1] = (t0 >>> 13 | t1 << 3) & 8191;
    this.r[2] = (t1 >>> 10 | t2 << 6) & 7939;
    this.r[3] = (t2 >>> 7 | t3 << 9) & 8191;
    this.r[4] = (t3 >>> 4 | t4 << 12) & 255;
    this.r[5] = t4 >>> 1 & 8190;
    this.r[6] = (t4 >>> 14 | t5 << 2) & 8191;
    this.r[7] = (t5 >>> 11 | t6 << 5) & 8065;
    this.r[8] = (t6 >>> 8 | t7 << 8) & 8191;
    this.r[9] = t7 >>> 5 & 127;
    for (let i4 = 0; i4 < 8; i4++)
      this.pad[i4] = u8to16(key, 16 + 2 * i4);
  }
  process(data, offset, isLast = false) {
    const hibit = isLast ? 0 : 1 << 11;
    const { h, r } = this;
    const r0 = r[0];
    const r1 = r[1];
    const r2 = r[2];
    const r3 = r[3];
    const r4 = r[4];
    const r5 = r[5];
    const r6 = r[6];
    const r7 = r[7];
    const r8 = r[8];
    const r9 = r[9];
    const t0 = u8to16(data, offset + 0);
    const t1 = u8to16(data, offset + 2);
    const t2 = u8to16(data, offset + 4);
    const t3 = u8to16(data, offset + 6);
    const t4 = u8to16(data, offset + 8);
    const t5 = u8to16(data, offset + 10);
    const t6 = u8to16(data, offset + 12);
    const t7 = u8to16(data, offset + 14);
    let h0 = h[0] + (t0 & 8191);
    let h1 = h[1] + ((t0 >>> 13 | t1 << 3) & 8191);
    let h2 = h[2] + ((t1 >>> 10 | t2 << 6) & 8191);
    let h3 = h[3] + ((t2 >>> 7 | t3 << 9) & 8191);
    let h4 = h[4] + ((t3 >>> 4 | t4 << 12) & 8191);
    let h5 = h[5] + (t4 >>> 1 & 8191);
    let h6 = h[6] + ((t4 >>> 14 | t5 << 2) & 8191);
    let h7 = h[7] + ((t5 >>> 11 | t6 << 5) & 8191);
    let h8 = h[8] + ((t6 >>> 8 | t7 << 8) & 8191);
    let h9 = h[9] + (t7 >>> 5 | hibit);
    let c = 0;
    let d0 = c + h0 * r0 + h1 * (5 * r9) + h2 * (5 * r8) + h3 * (5 * r7) + h4 * (5 * r6);
    c = d0 >>> 13;
    d0 &= 8191;
    d0 += h5 * (5 * r5) + h6 * (5 * r4) + h7 * (5 * r3) + h8 * (5 * r2) + h9 * (5 * r1);
    c += d0 >>> 13;
    d0 &= 8191;
    let d1 = c + h0 * r1 + h1 * r0 + h2 * (5 * r9) + h3 * (5 * r8) + h4 * (5 * r7);
    c = d1 >>> 13;
    d1 &= 8191;
    d1 += h5 * (5 * r6) + h6 * (5 * r5) + h7 * (5 * r4) + h8 * (5 * r3) + h9 * (5 * r2);
    c += d1 >>> 13;
    d1 &= 8191;
    let d2 = c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * (5 * r9) + h4 * (5 * r8);
    c = d2 >>> 13;
    d2 &= 8191;
    d2 += h5 * (5 * r7) + h6 * (5 * r6) + h7 * (5 * r5) + h8 * (5 * r4) + h9 * (5 * r3);
    c += d2 >>> 13;
    d2 &= 8191;
    let d3 = c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * (5 * r9);
    c = d3 >>> 13;
    d3 &= 8191;
    d3 += h5 * (5 * r8) + h6 * (5 * r7) + h7 * (5 * r6) + h8 * (5 * r5) + h9 * (5 * r4);
    c += d3 >>> 13;
    d3 &= 8191;
    let d4 = c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
    c = d4 >>> 13;
    d4 &= 8191;
    d4 += h5 * (5 * r9) + h6 * (5 * r8) + h7 * (5 * r7) + h8 * (5 * r6) + h9 * (5 * r5);
    c += d4 >>> 13;
    d4 &= 8191;
    let d5 = c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1;
    c = d5 >>> 13;
    d5 &= 8191;
    d5 += h5 * r0 + h6 * (5 * r9) + h7 * (5 * r8) + h8 * (5 * r7) + h9 * (5 * r6);
    c += d5 >>> 13;
    d5 &= 8191;
    let d6 = c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2;
    c = d6 >>> 13;
    d6 &= 8191;
    d6 += h5 * r1 + h6 * r0 + h7 * (5 * r9) + h8 * (5 * r8) + h9 * (5 * r7);
    c += d6 >>> 13;
    d6 &= 8191;
    let d7 = c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3;
    c = d7 >>> 13;
    d7 &= 8191;
    d7 += h5 * r2 + h6 * r1 + h7 * r0 + h8 * (5 * r9) + h9 * (5 * r8);
    c += d7 >>> 13;
    d7 &= 8191;
    let d8 = c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4;
    c = d8 >>> 13;
    d8 &= 8191;
    d8 += h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * (5 * r9);
    c += d8 >>> 13;
    d8 &= 8191;
    let d9 = c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5;
    c = d9 >>> 13;
    d9 &= 8191;
    d9 += h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
    c += d9 >>> 13;
    d9 &= 8191;
    c = (c << 2) + c | 0;
    c = c + d0 | 0;
    d0 = c & 8191;
    c = c >>> 13;
    d1 += c;
    h[0] = d0;
    h[1] = d1;
    h[2] = d2;
    h[3] = d3;
    h[4] = d4;
    h[5] = d5;
    h[6] = d6;
    h[7] = d7;
    h[8] = d8;
    h[9] = d9;
  }
  finalize() {
    const { h, pad: pad3 } = this;
    const g = new Uint16Array(10);
    let c = h[1] >>> 13;
    h[1] &= 8191;
    for (let i4 = 2; i4 < 10; i4++) {
      h[i4] += c;
      c = h[i4] >>> 13;
      h[i4] &= 8191;
    }
    h[0] += c * 5;
    c = h[0] >>> 13;
    h[0] &= 8191;
    h[1] += c;
    c = h[1] >>> 13;
    h[1] &= 8191;
    h[2] += c;
    g[0] = h[0] + 5;
    c = g[0] >>> 13;
    g[0] &= 8191;
    for (let i4 = 1; i4 < 10; i4++) {
      g[i4] = h[i4] + c;
      c = g[i4] >>> 13;
      g[i4] &= 8191;
    }
    g[9] -= 1 << 13;
    let mask = (c ^ 1) - 1;
    for (let i4 = 0; i4 < 10; i4++)
      g[i4] &= mask;
    mask = ~mask;
    for (let i4 = 0; i4 < 10; i4++)
      h[i4] = h[i4] & mask | g[i4];
    h[0] = (h[0] | h[1] << 13) & 65535;
    h[1] = (h[1] >>> 3 | h[2] << 10) & 65535;
    h[2] = (h[2] >>> 6 | h[3] << 7) & 65535;
    h[3] = (h[3] >>> 9 | h[4] << 4) & 65535;
    h[4] = (h[4] >>> 12 | h[5] << 1 | h[6] << 14) & 65535;
    h[5] = (h[6] >>> 2 | h[7] << 11) & 65535;
    h[6] = (h[7] >>> 5 | h[8] << 8) & 65535;
    h[7] = (h[8] >>> 8 | h[9] << 5) & 65535;
    let f = h[0] + pad3[0];
    h[0] = f & 65535;
    for (let i4 = 1; i4 < 8; i4++) {
      f = (h[i4] + pad3[i4] | 0) + (f >>> 16) | 0;
      h[i4] = f & 65535;
    }
    clean2(g);
  }
  update(data) {
    aexists2(this);
    abytes2(data);
    data = copyBytes2(data);
    const { buffer, blockLen } = this;
    const len = data.length;
    for (let pos = 0; pos < len; ) {
      const take = Math.min(blockLen - this.pos, len - pos);
      if (take === blockLen) {
        for (; blockLen <= len - pos; pos += blockLen)
          this.process(data, pos);
        continue;
      }
      buffer.set(data.subarray(pos, pos + take), this.pos);
      this.pos += take;
      pos += take;
      if (this.pos === blockLen) {
        this.process(buffer, 0, false);
        this.pos = 0;
      }
    }
    return this;
  }
  destroy() {
    clean2(this.h, this.r, this.buffer, this.pad);
  }
  digestInto(out) {
    aexists2(this);
    aoutput2(out, this);
    this.finished = true;
    const { buffer, h } = this;
    let { pos } = this;
    if (pos) {
      buffer[pos++] = 1;
      for (; pos < 16; pos++)
        buffer[pos] = 0;
      this.process(buffer, 0, true);
    }
    this.finalize();
    let opos = 0;
    for (let i4 = 0; i4 < 8; i4++) {
      out[opos++] = h[i4] >>> 0;
      out[opos++] = h[i4] >>> 8;
    }
    return out;
  }
  digest() {
    const { buffer, outputLen } = this;
    this.digestInto(buffer);
    const res = buffer.slice(0, outputLen);
    this.destroy();
    return res;
  }
};
function wrapConstructorWithKey(hashCons) {
  const hashC = (msg, key) => hashCons(key).update(msg).digest();
  const tmp = hashCons(new Uint8Array(32));
  hashC.outputLen = tmp.outputLen;
  hashC.blockLen = tmp.blockLen;
  hashC.create = (key) => hashCons(key);
  return hashC;
}
var poly1305 = /* @__PURE__ */ (() => wrapConstructorWithKey((key) => new Poly1305(key)))();

// node_modules/@noble/ciphers/chacha.js
function chachaCore(s, k, n, out, cnt, rounds = 20) {
  let y00 = s[0], y01 = s[1], y02 = s[2], y03 = s[3], y04 = k[0], y05 = k[1], y06 = k[2], y07 = k[3], y08 = k[4], y09 = k[5], y10 = k[6], y11 = k[7], y12 = cnt, y13 = n[0], y14 = n[1], y15 = n[2];
  let x00 = y00, x01 = y01, x02 = y02, x03 = y03, x04 = y04, x05 = y05, x06 = y06, x07 = y07, x08 = y08, x09 = y09, x10 = y10, x11 = y11, x12 = y12, x13 = y13, x14 = y14, x15 = y15;
  for (let r = 0; r < rounds; r += 2) {
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 16);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 12);
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 8);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 7);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 16);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 12);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 8);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 7);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 16);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 12);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 8);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 7);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 16);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 12);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 8);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 7);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 16);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 12);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 8);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 7);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 16);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 12);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 8);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 7);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 16);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 12);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 8);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 7);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 16);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 12);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 8);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 7);
  }
  let oi = 0;
  out[oi++] = y00 + x00 | 0;
  out[oi++] = y01 + x01 | 0;
  out[oi++] = y02 + x02 | 0;
  out[oi++] = y03 + x03 | 0;
  out[oi++] = y04 + x04 | 0;
  out[oi++] = y05 + x05 | 0;
  out[oi++] = y06 + x06 | 0;
  out[oi++] = y07 + x07 | 0;
  out[oi++] = y08 + x08 | 0;
  out[oi++] = y09 + x09 | 0;
  out[oi++] = y10 + x10 | 0;
  out[oi++] = y11 + x11 | 0;
  out[oi++] = y12 + x12 | 0;
  out[oi++] = y13 + x13 | 0;
  out[oi++] = y14 + x14 | 0;
  out[oi++] = y15 + x15 | 0;
}
function hchacha(s, k, i4, out) {
  let x00 = s[0], x01 = s[1], x02 = s[2], x03 = s[3], x04 = k[0], x05 = k[1], x06 = k[2], x07 = k[3], x08 = k[4], x09 = k[5], x10 = k[6], x11 = k[7], x12 = i4[0], x13 = i4[1], x14 = i4[2], x15 = i4[3];
  for (let r = 0; r < 20; r += 2) {
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 16);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 12);
    x00 = x00 + x04 | 0;
    x12 = rotl(x12 ^ x00, 8);
    x08 = x08 + x12 | 0;
    x04 = rotl(x04 ^ x08, 7);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 16);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 12);
    x01 = x01 + x05 | 0;
    x13 = rotl(x13 ^ x01, 8);
    x09 = x09 + x13 | 0;
    x05 = rotl(x05 ^ x09, 7);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 16);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 12);
    x02 = x02 + x06 | 0;
    x14 = rotl(x14 ^ x02, 8);
    x10 = x10 + x14 | 0;
    x06 = rotl(x06 ^ x10, 7);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 16);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 12);
    x03 = x03 + x07 | 0;
    x15 = rotl(x15 ^ x03, 8);
    x11 = x11 + x15 | 0;
    x07 = rotl(x07 ^ x11, 7);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 16);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 12);
    x00 = x00 + x05 | 0;
    x15 = rotl(x15 ^ x00, 8);
    x10 = x10 + x15 | 0;
    x05 = rotl(x05 ^ x10, 7);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 16);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 12);
    x01 = x01 + x06 | 0;
    x12 = rotl(x12 ^ x01, 8);
    x11 = x11 + x12 | 0;
    x06 = rotl(x06 ^ x11, 7);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 16);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 12);
    x02 = x02 + x07 | 0;
    x13 = rotl(x13 ^ x02, 8);
    x08 = x08 + x13 | 0;
    x07 = rotl(x07 ^ x08, 7);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 16);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 12);
    x03 = x03 + x04 | 0;
    x14 = rotl(x14 ^ x03, 8);
    x09 = x09 + x14 | 0;
    x04 = rotl(x04 ^ x09, 7);
  }
  let oi = 0;
  out[oi++] = x00;
  out[oi++] = x01;
  out[oi++] = x02;
  out[oi++] = x03;
  out[oi++] = x12;
  out[oi++] = x13;
  out[oi++] = x14;
  out[oi++] = x15;
}
var chacha20 = /* @__PURE__ */ createCipher(chachaCore, {
  counterRight: false,
  counterLength: 4,
  allowShortKeys: false
});
var xchacha20 = /* @__PURE__ */ createCipher(chachaCore, {
  counterRight: false,
  counterLength: 8,
  extendNonceFn: hchacha,
  allowShortKeys: false
});
var ZEROS16 = /* @__PURE__ */ new Uint8Array(16);
var updatePadded = (h, msg) => {
  h.update(msg);
  const leftover = msg.length % 16;
  if (leftover)
    h.update(ZEROS16.subarray(leftover));
};
var ZEROS32 = /* @__PURE__ */ new Uint8Array(32);
function computeTag(fn, key, nonce, ciphertext, AAD) {
  if (AAD !== void 0)
    abytes2(AAD, void 0, "AAD");
  const authKey = fn(key, nonce, ZEROS32);
  const lengths = u64Lengths(ciphertext.length, AAD ? AAD.length : 0, true);
  const h = poly1305.create(authKey);
  if (AAD)
    updatePadded(h, AAD);
  updatePadded(h, ciphertext);
  h.update(lengths);
  const res = h.digest();
  clean2(authKey, lengths);
  return res;
}
var _poly1305_aead = (xorStream) => (key, nonce, AAD) => {
  const tagLength = 16;
  return {
    encrypt(plaintext, output) {
      const plength = plaintext.length;
      output = getOutput(plength + tagLength, output, false);
      output.set(plaintext);
      const oPlain = output.subarray(0, -tagLength);
      xorStream(key, nonce, oPlain, oPlain, 1);
      const tag = computeTag(xorStream, key, nonce, oPlain, AAD);
      output.set(tag, plength);
      clean2(tag);
      return output;
    },
    decrypt(ciphertext, output) {
      output = getOutput(ciphertext.length - tagLength, output, false);
      const data = ciphertext.subarray(0, -tagLength);
      const passedTag = ciphertext.subarray(-tagLength);
      const tag = computeTag(xorStream, key, nonce, data, AAD);
      if (!equalBytes(passedTag, tag))
        throw new Error("invalid tag");
      output.set(ciphertext.subarray(0, -tagLength));
      xorStream(key, nonce, output, output, 1);
      clean2(tag);
      return output;
    }
  };
};
var chacha20poly1305 = /* @__PURE__ */ wrapCipher({ blockSize: 64, nonceLength: 12, tagLength: 16 }, _poly1305_aead(chacha20));
var xchacha20poly1305 = /* @__PURE__ */ wrapCipher({ blockSize: 64, nonceLength: 24, tagLength: 16 }, _poly1305_aead(xchacha20));

// node_modules/@noble/hashes/hkdf.js
function extract(hash, ikm, salt) {
  ahash(hash);
  if (salt === void 0)
    salt = new Uint8Array(hash.outputLen);
  return hmac(hash, salt, ikm);
}
var HKDF_COUNTER = /* @__PURE__ */ Uint8Array.of(0);
var EMPTY_BUFFER = /* @__PURE__ */ Uint8Array.of();
function expand(hash, prk, info, length = 32) {
  ahash(hash);
  anumber(length, "length");
  const olen = hash.outputLen;
  if (length > 255 * olen)
    throw new Error("Length must be <= 255*HashLen");
  const blocks = Math.ceil(length / olen);
  if (info === void 0)
    info = EMPTY_BUFFER;
  else
    abytes(info, void 0, "info");
  const okm = new Uint8Array(blocks * olen);
  const HMAC = hmac.create(hash, prk);
  const HMACTmp = HMAC._cloneInto();
  const T = new Uint8Array(HMAC.outputLen);
  for (let counter = 0; counter < blocks; counter++) {
    HKDF_COUNTER[0] = counter + 1;
    HMACTmp.update(counter === 0 ? EMPTY_BUFFER : T).update(info).update(HKDF_COUNTER).digestInto(T);
    okm.set(T, olen * counter);
    HMAC._cloneInto(HMACTmp);
  }
  HMAC.destroy();
  HMACTmp.destroy();
  clean(T, HKDF_COUNTER);
  return okm.slice(0, length);
}

// node_modules/nostr-tools/lib/esm/nip44.js
var utf8Decoder4 = new TextDecoder("utf-8");
var utf8Encoder4 = new TextEncoder();
var minPlaintextSize = 1;
var maxPlaintextSize = 4294967295;
var extendedPrefixThreshold = 65536;
function getConversationKey(privkeyA, pubkeyB) {
  const sharedX = secp256k1.getSharedSecret(privkeyA, hexToBytes("02" + pubkeyB)).subarray(1, 33);
  return extract(sha256, sharedX, utf8Encoder4.encode("nip44-v2"));
}
function getMessageKeys(conversationKey, nonce) {
  const keys = expand(sha256, conversationKey, nonce, 76);
  return {
    chacha_key: keys.subarray(0, 32),
    chacha_nonce: keys.subarray(32, 44),
    hmac_key: keys.subarray(44, 76)
  };
}
function calcPaddedLen(len) {
  if (!Number.isSafeInteger(len) || len < 1)
    throw new Error("expected positive integer");
  if (len <= 32)
    return 32;
  const nextPower = 2 ** (Math.floor(Math.log2(len - 1)) + 1);
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((len - 1) / chunk) + 1);
}
function writeU16BE(num2) {
  if (!Number.isSafeInteger(num2) || num2 < minPlaintextSize || num2 > 65535)
    throw new Error("invalid plaintext size: must be between 1 and 65535 bytes");
  const arr = new Uint8Array(2);
  new DataView(arr.buffer).setUint16(0, num2, false);
  return arr;
}
function writeU32BE(num2) {
  if (!Number.isSafeInteger(num2) || num2 < extendedPrefixThreshold || num2 > maxPlaintextSize)
    throw new Error("invalid plaintext size: must be between 65536 and 4294967295 bytes");
  const arr = new Uint8Array(4);
  new DataView(arr.buffer).setUint32(0, num2, false);
  return arr;
}
function pad(plaintext) {
  const unpadded = utf8Encoder4.encode(plaintext);
  const unpaddedLen = unpadded.length;
  if (unpaddedLen < minPlaintextSize || unpaddedLen > maxPlaintextSize)
    throw new Error("invalid plaintext size: must be between 1 and 4294967295 bytes");
  const prefix = unpaddedLen >= extendedPrefixThreshold ? concatBytes(new Uint8Array([0, 0]), writeU32BE(unpaddedLen)) : writeU16BE(unpaddedLen);
  const suffix = new Uint8Array(calcPaddedLen(unpaddedLen) - unpaddedLen);
  return concatBytes(prefix, unpadded, suffix);
}
function unpad(padded) {
  const dv = new DataView(padded.buffer, padded.byteOffset, padded.byteLength);
  const firstTwo = dv.getUint16(0);
  let unpaddedLen;
  let prefixLen;
  if (firstTwo === 0) {
    unpaddedLen = dv.getUint32(2);
    if (unpaddedLen < extendedPrefixThreshold)
      throw new Error("invalid padding");
    prefixLen = 6;
  } else {
    unpaddedLen = firstTwo;
    prefixLen = 2;
  }
  const unpadded = padded.subarray(prefixLen, prefixLen + unpaddedLen);
  if (unpaddedLen < minPlaintextSize || unpaddedLen > maxPlaintextSize || unpadded.length !== unpaddedLen || padded.length !== prefixLen + calcPaddedLen(unpaddedLen))
    throw new Error("invalid padding");
  return utf8Decoder4.decode(unpadded);
}
function hmacAad(key, message, aad) {
  if (aad.length !== 32)
    throw new Error("AAD associated data must be 32 bytes");
  const combined = concatBytes(aad, message);
  return hmac(sha256, key, combined);
}
function decodePayload(payload) {
  if (typeof payload !== "string")
    throw new Error("payload must be a valid string");
  const plen = payload.length;
  if (plen < 132)
    throw new Error("invalid payload length: " + plen);
  if (payload[0] === "#")
    throw new Error("unknown encryption version");
  let data;
  try {
    data = base64.decode(payload);
  } catch (error) {
    throw new Error("invalid base64: " + error.message);
  }
  const dlen = data.length;
  if (dlen < 99)
    throw new Error("invalid data length: " + dlen);
  const vers = data[0];
  if (vers !== 2)
    throw new Error("unknown encryption version " + vers);
  return {
    nonce: data.subarray(1, 33),
    ciphertext: data.subarray(33, -32),
    mac: data.subarray(-32)
  };
}
function encrypt3(plaintext, conversationKey, nonce = randomBytes(32)) {
  const { chacha_key, chacha_nonce, hmac_key } = getMessageKeys(conversationKey, nonce);
  const padded = pad(plaintext);
  const ciphertext = chacha20(chacha_key, chacha_nonce, padded);
  const mac = hmacAad(hmac_key, ciphertext, nonce);
  return base64.encode(concatBytes(new Uint8Array([2]), nonce, ciphertext, mac));
}
function decrypt3(payload, conversationKey) {
  const { nonce, ciphertext, mac } = decodePayload(payload);
  const { chacha_key, chacha_nonce, hmac_key } = getMessageKeys(conversationKey, nonce);
  const calculatedMac = hmacAad(hmac_key, ciphertext, nonce);
  if (!equalBytes(calculatedMac, mac))
    throw new Error("invalid MAC");
  const padded = chacha20(chacha_key, chacha_nonce, ciphertext);
  return unpad(padded);
}

// node_modules/nostr-tools/lib/esm/nip46.js
var utf8Decoder5 = new TextDecoder("utf-8");
var utf8Encoder5 = new TextEncoder();
function normalizeURL2(url) {
  try {
    if (url.indexOf("://") === -1)
      url = "wss://" + url;
    let p = new URL(url);
    if (p.protocol === "http:")
      p.protocol = "ws:";
    else if (p.protocol === "https:")
      p.protocol = "wss:";
    p.pathname = p.pathname.replace(/\/+/g, "/");
    if (p.pathname.endsWith("/"))
      p.pathname = p.pathname.slice(0, -1);
    if (p.port === "80" && p.protocol === "ws:" || p.port === "443" && p.protocol === "wss:")
      p.port = "";
    p.searchParams.sort();
    p.hash = "";
    return p.toString();
  } catch (e) {
    throw new Error(`Invalid URL: ${url}`);
  }
}
function isHex323(input) {
  if (input.length !== 64)
    return false;
  for (let i22 = 0; i22 < 64; i22++) {
    let cc = input.charCodeAt(i22);
    if (isNaN(cc) || cc < 48 || cc > 102 || cc > 57 && cc < 97) {
      return false;
    }
  }
  return true;
}
var verifiedSymbol3 = Symbol("verified");
var isRecord3 = (obj) => obj instanceof Object;
function validateEvent3(event) {
  if (!isRecord3(event))
    return false;
  if (typeof event.kind !== "number")
    return false;
  if (typeof event.content !== "string")
    return false;
  if (typeof event.created_at !== "number")
    return false;
  if (typeof event.pubkey !== "string")
    return false;
  if (!isHex323(event.pubkey))
    return false;
  if (!Array.isArray(event.tags))
    return false;
  for (let i22 = 0; i22 < event.tags.length; i22++) {
    let tag = event.tags[i22];
    if (!Array.isArray(tag))
      return false;
    for (let j = 0; j < tag.length; j++) {
      if (typeof tag[j] !== "string")
        return false;
    }
  }
  return true;
}
var JS3 = class {
  generateSecretKey() {
    return schnorr.utils.randomSecretKey();
  }
  getPublicKey(secretKey) {
    return bytesToHex(schnorr.getPublicKey(secretKey));
  }
  finalizeEvent(t, secretKey) {
    const event = t;
    event.pubkey = bytesToHex(schnorr.getPublicKey(secretKey));
    event.id = getEventHash3(event);
    event.sig = bytesToHex(schnorr.sign(hexToBytes(getEventHash3(event)), secretKey));
    event[verifiedSymbol3] = true;
    return event;
  }
  verifyEvent(event) {
    if (typeof event[verifiedSymbol3] === "boolean")
      return event[verifiedSymbol3];
    try {
      const hash = getEventHash3(event);
      if (hash !== event.id) {
        event[verifiedSymbol3] = false;
        return false;
      }
      const valid = schnorr.verify(hexToBytes(event.sig), hexToBytes(hash), hexToBytes(event.pubkey));
      event[verifiedSymbol3] = valid;
      return valid;
    } catch (err) {
      event[verifiedSymbol3] = false;
      return false;
    }
  }
};
function serializeEvent3(evt) {
  if (!validateEvent3(evt))
    throw new Error("can't serialize event with wrong or missing properties");
  return JSON.stringify([0, evt.pubkey, evt.created_at, evt.kind, evt.tags, evt.content]);
}
function getEventHash3(event) {
  let eventHash = sha256(utf8Encoder5.encode(serializeEvent3(event)));
  return bytesToHex(eventHash);
}
var i3 = new JS3();
var generateSecretKey3 = i3.generateSecretKey;
var getPublicKey3 = i3.getPublicKey;
var finalizeEvent3 = i3.finalizeEvent;
var verifyEvent3 = i3.verifyEvent;
var minPlaintextSize2 = 1;
var maxPlaintextSize2 = 4294967295;
var extendedPrefixThreshold2 = 65536;
function getConversationKey2(privkeyA, pubkeyB) {
  const sharedX = secp256k1.getSharedSecret(privkeyA, hexToBytes("02" + pubkeyB)).subarray(1, 33);
  return extract(sha256, sharedX, utf8Encoder5.encode("nip44-v2"));
}
function getMessageKeys2(conversationKey, nonce) {
  const keys = expand(sha256, conversationKey, nonce, 76);
  return {
    chacha_key: keys.subarray(0, 32),
    chacha_nonce: keys.subarray(32, 44),
    hmac_key: keys.subarray(44, 76)
  };
}
function calcPaddedLen2(len) {
  if (!Number.isSafeInteger(len) || len < 1)
    throw new Error("expected positive integer");
  if (len <= 32)
    return 32;
  const nextPower = 2 ** (Math.floor(Math.log2(len - 1)) + 1);
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((len - 1) / chunk) + 1);
}
function writeU16BE2(num2) {
  if (!Number.isSafeInteger(num2) || num2 < minPlaintextSize2 || num2 > 65535)
    throw new Error("invalid plaintext size: must be between 1 and 65535 bytes");
  const arr = new Uint8Array(2);
  new DataView(arr.buffer).setUint16(0, num2, false);
  return arr;
}
function writeU32BE2(num2) {
  if (!Number.isSafeInteger(num2) || num2 < extendedPrefixThreshold2 || num2 > maxPlaintextSize2)
    throw new Error("invalid plaintext size: must be between 65536 and 4294967295 bytes");
  const arr = new Uint8Array(4);
  new DataView(arr.buffer).setUint32(0, num2, false);
  return arr;
}
function pad2(plaintext) {
  const unpadded = utf8Encoder5.encode(plaintext);
  const unpaddedLen = unpadded.length;
  if (unpaddedLen < minPlaintextSize2 || unpaddedLen > maxPlaintextSize2)
    throw new Error("invalid plaintext size: must be between 1 and 4294967295 bytes");
  const prefix = unpaddedLen >= extendedPrefixThreshold2 ? concatBytes(new Uint8Array([0, 0]), writeU32BE2(unpaddedLen)) : writeU16BE2(unpaddedLen);
  const suffix = new Uint8Array(calcPaddedLen2(unpaddedLen) - unpaddedLen);
  return concatBytes(prefix, unpadded, suffix);
}
function unpad2(padded) {
  const dv = new DataView(padded.buffer, padded.byteOffset, padded.byteLength);
  const firstTwo = dv.getUint16(0);
  let unpaddedLen;
  let prefixLen;
  if (firstTwo === 0) {
    unpaddedLen = dv.getUint32(2);
    if (unpaddedLen < extendedPrefixThreshold2)
      throw new Error("invalid padding");
    prefixLen = 6;
  } else {
    unpaddedLen = firstTwo;
    prefixLen = 2;
  }
  const unpadded = padded.subarray(prefixLen, prefixLen + unpaddedLen);
  if (unpaddedLen < minPlaintextSize2 || unpaddedLen > maxPlaintextSize2 || unpadded.length !== unpaddedLen || padded.length !== prefixLen + calcPaddedLen2(unpaddedLen))
    throw new Error("invalid padding");
  return utf8Decoder5.decode(unpadded);
}
function hmacAad2(key, message, aad) {
  if (aad.length !== 32)
    throw new Error("AAD associated data must be 32 bytes");
  const combined = concatBytes(aad, message);
  return hmac(sha256, key, combined);
}
function decodePayload2(payload) {
  if (typeof payload !== "string")
    throw new Error("payload must be a valid string");
  const plen = payload.length;
  if (plen < 132)
    throw new Error("invalid payload length: " + plen);
  if (payload[0] === "#")
    throw new Error("unknown encryption version");
  let data;
  try {
    data = base64.decode(payload);
  } catch (error) {
    throw new Error("invalid base64: " + error.message);
  }
  const dlen = data.length;
  if (dlen < 99)
    throw new Error("invalid data length: " + dlen);
  const vers = data[0];
  if (vers !== 2)
    throw new Error("unknown encryption version " + vers);
  return {
    nonce: data.subarray(1, 33),
    ciphertext: data.subarray(33, -32),
    mac: data.subarray(-32)
  };
}
function encrypt4(plaintext, conversationKey, nonce = randomBytes(32)) {
  const { chacha_key, chacha_nonce, hmac_key } = getMessageKeys2(conversationKey, nonce);
  const padded = pad2(plaintext);
  const ciphertext = chacha20(chacha_key, chacha_nonce, padded);
  const mac = hmacAad2(hmac_key, ciphertext, nonce);
  return base64.encode(concatBytes(new Uint8Array([2]), nonce, ciphertext, mac));
}
function decrypt4(payload, conversationKey) {
  const { nonce, ciphertext, mac } = decodePayload2(payload);
  const { chacha_key, chacha_nonce, hmac_key } = getMessageKeys2(conversationKey, nonce);
  const calculatedMac = hmacAad2(hmac_key, ciphertext, nonce);
  if (!equalBytes(calculatedMac, mac))
    throw new Error("invalid MAC");
  const padded = chacha20(chacha_key, chacha_nonce, ciphertext);
  return unpad2(padded);
}
var NIP05_REGEX = /^(?:([\w.+-]+)@)?([\w_-]+(\.[\w_-]+)+)$/;
var _fetch;
try {
  _fetch = fetch;
} catch (_) {
  null;
}
var ClientAuth2 = 22242;
var NostrConnect = 24133;
function matchFilter2(filter, event) {
  if (filter.ids && filter.ids.indexOf(event.id) === -1) {
    return false;
  }
  if (filter.kinds && filter.kinds.indexOf(event.kind) === -1) {
    return false;
  }
  if (filter.authors && filter.authors.indexOf(event.pubkey) === -1) {
    return false;
  }
  for (let f in filter) {
    if (f[0] === "#") {
      let tagName = f.slice(1);
      let values = filter[`#${tagName}`];
      if (values && !event.tags.find(([t, v]) => t === f.slice(1) && values.indexOf(v) !== -1))
        return false;
    }
  }
  if (filter.since && event.created_at < filter.since)
    return false;
  if (filter.until && event.created_at > filter.until)
    return false;
  return true;
}
function matchFilters2(filters2, event) {
  for (let i22 = 0; i22 < filters2.length; i22++) {
    if (matchFilter2(filters2[i22], event)) {
      return true;
    }
  }
  return false;
}
function getHex642(json, field) {
  let len = field.length + 3;
  let idx = json.indexOf(`"${field}":`) + len;
  let s = json.slice(idx).indexOf(`"`) + idx + 1;
  return json.slice(s, s + 64);
}
function getSubscriptionId2(json) {
  let idx = json.slice(0, 22).indexOf(`"EVENT"`);
  if (idx === -1)
    return null;
  let pstart = json.slice(idx + 7 + 1).indexOf(`"`);
  if (pstart === -1)
    return null;
  let start = idx + 7 + 1 + pstart;
  let pend = json.slice(start + 1, 80).indexOf(`"`);
  if (pend === -1)
    return null;
  let end = start + 1 + pend;
  return json.slice(start + 1, end);
}
function makeAuthEvent2(relayURL, challenge2) {
  return {
    kind: ClientAuth2,
    created_at: Math.floor(Date.now() / 1e3),
    tags: [
      ["relay", relayURL],
      ["challenge", challenge2]
    ],
    content: ""
  };
}
var SendingOnClosedConnection2 = class extends Error {
  constructor(message, relay) {
    super(`Tried to send message '${message} on a closed connection to ${relay}.`);
    this.name = "SendingOnClosedConnection";
  }
};
var AbstractRelay2 = class {
  url;
  _connected = false;
  onclose = null;
  onnotice = (msg) => console.debug(`NOTICE from ${this.url}: ${msg}`);
  onauth;
  baseEoseTimeout = 4400;
  publishTimeout = 4400;
  pingFrequency = 29e3;
  pingTimeout = 2e4;
  resubscribeBackoff = [1e4, 1e4, 1e4, 2e4, 2e4, 3e4, 6e4];
  openSubs = /* @__PURE__ */ new Map();
  enablePing;
  enableReconnect;
  idleTimeout = 0;
  idleSince = Date.now();
  ongoingOperations = 0;
  reconnectTimeoutHandle;
  pingIntervalHandle;
  reconnectAttempts = 0;
  skipReconnection = false;
  idleTimeoutHandle;
  connectionPromise;
  openCountRequests = /* @__PURE__ */ new Map();
  openEventPublishes = /* @__PURE__ */ new Map();
  ws;
  challenge;
  authPromise;
  serial = 0;
  verifyEvent;
  _WebSocket;
  constructor(url, opts) {
    this.url = normalizeURL2(url);
    this.verifyEvent = opts.verifyEvent;
    this._WebSocket = opts.websocketImplementation || WebSocket;
    this.enablePing = opts.enablePing;
    this.enableReconnect = opts.enableReconnect || false;
    if (opts.idleTimeout)
      this.idleTimeout = opts.idleTimeout;
  }
  static async connect(url, opts) {
    const relay = new AbstractRelay2(url, opts);
    await relay.connect(opts);
    return relay;
  }
  closeAllSubscriptions(reason) {
    for (let [_, sub] of this.openSubs) {
      sub.close(reason);
    }
    this.openSubs.clear();
    for (let [_, ep] of this.openEventPublishes) {
      ep.reject(new Error(reason));
    }
    this.openEventPublishes.clear();
    for (let [_, cr] of this.openCountRequests) {
      cr.reject(new Error(reason));
    }
    this.openCountRequests.clear();
  }
  get connected() {
    return this._connected;
  }
  clearIdleTimeout() {
    if (this.idleTimeoutHandle) {
      clearTimeout(this.idleTimeoutHandle);
      this.idleTimeoutHandle = void 0;
    }
  }
  scheduleIdleClose() {
    this.clearIdleTimeout();
    if (this.idleTimeout > 0) {
      this.idleTimeoutHandle = setTimeout(() => {
        if (this.ongoingOperations === 0 && this.idleSince) {
          this.close();
        }
      }, this.idleTimeout);
    }
  }
  async reconnect() {
    const backoff = this.resubscribeBackoff[Math.min(this.reconnectAttempts, this.resubscribeBackoff.length - 1)];
    this.reconnectAttempts++;
    this.reconnectTimeoutHandle = setTimeout(async () => {
      try {
        await this.connect();
      } catch (err) {
      }
    }, backoff);
  }
  handleHardClose(reason) {
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
    }
    if (this.pingIntervalHandle) {
      clearInterval(this.pingIntervalHandle);
      this.pingIntervalHandle = void 0;
    }
    this._connected = false;
    this.connectionPromise = void 0;
    this.idleSince = void 0;
    this.clearIdleTimeout();
    if (this.enableReconnect && !this.skipReconnection) {
      this.reconnect();
    } else {
      this.onclose?.();
      this.closeAllSubscriptions(reason);
    }
  }
  async connect(opts) {
    let connectionTimeoutHandle;
    if (this.connectionPromise)
      return this.connectionPromise;
    this.challenge = void 0;
    this.authPromise = void 0;
    this.skipReconnection = false;
    this.connectionPromise = new Promise((resolve, reject) => {
      if (opts?.timeout) {
        connectionTimeoutHandle = setTimeout(() => {
          reject("connection timed out");
          this.connectionPromise = void 0;
          if (this.reconnectAttempts === 0) {
            this.skipReconnection = true;
          }
          this.ws?.close?.();
          this.handleHardClose("relay connection timed out");
        }, opts.timeout);
      }
      if (opts?.abort) {
        opts.abort.onabort = reject;
      }
      try {
        this.ws = new this._WebSocket(this.url);
      } catch (err) {
        clearTimeout(connectionTimeoutHandle);
        reject(err);
        return;
      }
      this.ws.onopen = () => {
        if (this.reconnectTimeoutHandle) {
          clearTimeout(this.reconnectTimeoutHandle);
          this.reconnectTimeoutHandle = void 0;
        }
        clearTimeout(connectionTimeoutHandle);
        this._connected = true;
        const isReconnection = this.reconnectAttempts > 0;
        this.reconnectAttempts = 0;
        for (const sub of this.openSubs.values()) {
          sub.eosed = false;
          if (isReconnection) {
            for (let f = 0; f < sub.filters.length; f++) {
              if (sub.lastEmitted) {
                sub.filters[f].since = sub.lastEmitted + 1;
              }
            }
          }
          sub.fire();
        }
        if (this.enablePing) {
          this.pingIntervalHandle = setInterval(() => this.pingpong(), this.pingFrequency);
        }
        resolve();
      };
      this.ws.onerror = () => {
        clearTimeout(connectionTimeoutHandle);
        reject("connection failed");
        this.connectionPromise = void 0;
        if (this.reconnectAttempts === 0) {
          this.skipReconnection = true;
        }
        this.ws?.close?.();
        this.handleHardClose("relay connection failed");
      };
      this.ws.onclose = (ev) => {
        clearTimeout(connectionTimeoutHandle);
        reject(ev.message || "websocket closed");
        this.handleHardClose("relay connection closed");
      };
      this.ws.onmessage = this._onmessage.bind(this);
    });
    return this.connectionPromise;
  }
  waitForPingPong() {
    return new Promise((resolve) => {
      ;
      this.ws.once("pong", () => resolve(true));
      this.ws.ping();
    });
  }
  waitForDummyReq() {
    return new Promise((resolve, reject) => {
      if (!this.connectionPromise)
        return reject(new Error(`no connection to ${this.url}, can't ping`));
      try {
        const sub = this.subscribe(
          [{ ids: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], limit: 1 }],
          {
            label: "<forced-ping>",
            oneose: () => {
              resolve(true);
              sub.close();
            },
            onclose() {
              resolve(true);
            },
            eoseTimeout: this.pingTimeout + 1e3
          }
        );
      } catch (err) {
        reject(err);
      }
    });
  }
  async pingpong() {
    if (this.ws?.readyState === 1) {
      const result = await Promise.any([
        this.ws && this.ws.ping && this.ws.once ? this.waitForPingPong() : this.waitForDummyReq(),
        new Promise((res) => setTimeout(() => res(false), this.pingTimeout))
      ]);
      if (!result) {
        if (this.ws?.readyState === this._WebSocket.OPEN) {
          this.ws?.close();
        }
      }
    }
  }
  async send(message) {
    if (!this.connectionPromise)
      throw new SendingOnClosedConnection2(message, this.url);
    this.connectionPromise.then(() => {
      this.ws?.send(message);
    });
  }
  async auth(signAuthEvent) {
    const challenge2 = this.challenge;
    if (!challenge2)
      throw new Error("can't perform auth, no challenge was received");
    if (this.authPromise)
      return this.authPromise;
    this.authPromise = new Promise(async (resolve, reject) => {
      try {
        let evt = await signAuthEvent(makeAuthEvent2(this.url, challenge2));
        let timeout = setTimeout(() => {
          let ep = this.openEventPublishes.get(evt.id);
          if (ep) {
            ep.reject(new Error("auth timed out"));
            this.openEventPublishes.delete(evt.id);
          }
        }, this.publishTimeout);
        this.openEventPublishes.set(evt.id, { resolve, reject, timeout });
        this.send('["AUTH",' + JSON.stringify(evt) + "]");
      } catch (err) {
        console.warn("subscribe auth function failed:", err);
      }
    });
    return this.authPromise;
  }
  async publish(event) {
    this.idleSince = void 0;
    this.clearIdleTimeout();
    this.ongoingOperations++;
    const ret = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const ep = this.openEventPublishes.get(event.id);
        if (ep) {
          ep.reject(new Error("publish timed out"));
          this.openEventPublishes.delete(event.id);
        }
      }, this.publishTimeout);
      this.openEventPublishes.set(event.id, { resolve, reject, timeout });
    });
    try {
      await this.send('["EVENT",' + JSON.stringify(event) + "]");
    } catch (err) {
      const ep = this.openEventPublishes.get(event.id);
      if (ep) {
        ep.reject(err);
        this.openEventPublishes.delete(event.id);
      }
    }
    this.ongoingOperations--;
    if (this.ongoingOperations === 0) {
      this.idleSince = Date.now();
      this.scheduleIdleClose();
    }
    return ret;
  }
  async count(filters2, params) {
    return (await this.countWithHLL(filters2, params)).count;
  }
  async countWithHLL(filters2, params) {
    this.serial++;
    const id = params?.id || "count:" + this.serial;
    const ret = new Promise((resolve, reject) => {
      this.openCountRequests.set(id, { resolve, reject });
    });
    try {
      await this.send('["COUNT","' + id + '",' + JSON.stringify(filters2).substring(1));
    } catch (err) {
      const cr = this.openCountRequests.get(id);
      if (cr) {
        cr.reject(err);
        this.openCountRequests.delete(id);
      }
    }
    return ret;
  }
  subscribe(filters2, params) {
    if (params.label !== "<forced-ping>") {
      this.idleSince = void 0;
      this.clearIdleTimeout();
      this.ongoingOperations++;
    }
    const sub = this.prepareSubscription(filters2, params);
    sub.fire();
    if (params.abort) {
      params.abort.onabort = () => sub.close(String(params.abort.reason || "<aborted>"));
    }
    return sub;
  }
  prepareSubscription(filters2, params) {
    this.serial++;
    const id = params.id || (params.label ? params.label + ":" : "sub:") + this.serial;
    const sub = new Subscription2(this, id, filters2, params);
    this.openSubs.set(id, sub);
    return sub;
  }
  close() {
    this.skipReconnection = true;
    if (this.reconnectTimeoutHandle) {
      clearTimeout(this.reconnectTimeoutHandle);
      this.reconnectTimeoutHandle = void 0;
    }
    if (this.pingIntervalHandle) {
      clearInterval(this.pingIntervalHandle);
      this.pingIntervalHandle = void 0;
    }
    this.closeAllSubscriptions("relay connection closed by us");
    this._connected = false;
    this.connectionPromise = void 0;
    this.idleSince = void 0;
    this.clearIdleTimeout();
    this.onclose?.();
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
      if (this.ws.readyState !== this._WebSocket.CLOSING && this.ws.readyState !== this._WebSocket.CLOSED) {
        this.ws.close();
      }
    }
  }
  _onmessage(ev) {
    const json = ev.data;
    if (!json) {
      return;
    }
    const subid = getSubscriptionId2(json);
    if (subid) {
      const so = this.openSubs.get(subid);
      if (!so) {
        return;
      }
      const id = getHex642(json, "id");
      const alreadyHave = so.alreadyHaveEvent?.(id);
      so.receivedEvent?.(this, id);
      if (alreadyHave) {
        return;
      }
    }
    try {
      let data = JSON.parse(json);
      switch (data[0]) {
        case "EVENT": {
          const so = this.openSubs.get(data[1]);
          const event = data[2];
          if (matchFilters2(so.filters, event) && this.verifyEvent(event, this.url)) {
            so.onevent(event);
          } else {
            so.oninvalidevent?.(event);
          }
          if (!so.lastEmitted || so.lastEmitted < event.created_at)
            so.lastEmitted = event.created_at;
          return;
        }
        case "COUNT": {
          const id = data[1];
          const payload = data[2];
          const cr = this.openCountRequests.get(id);
          if (cr) {
            cr.resolve(payload);
            this.openCountRequests.delete(id);
          }
          return;
        }
        case "EOSE": {
          const so = this.openSubs.get(data[1]);
          if (!so)
            return;
          so.receivedEose();
          return;
        }
        case "OK": {
          const id = data[1];
          const ok = data[2];
          const reason = data[3];
          const ep = this.openEventPublishes.get(id);
          if (ep) {
            clearTimeout(ep.timeout);
            if (ok)
              ep.resolve(reason);
            else
              ep.reject(new Error(reason));
            this.openEventPublishes.delete(id);
          }
          return;
        }
        case "CLOSED": {
          const id = data[1];
          const so = this.openSubs.get(id);
          if (!so) {
            const cr = this.openCountRequests.get(id);
            if (cr) {
              cr.reject(new Error(data[2]));
              this.openCountRequests.delete(id);
            }
            return;
          }
          so.closed = true;
          so.close(data[2]);
          return;
        }
        case "NOTICE": {
          this.onnotice(data[1]);
          return;
        }
        case "AUTH": {
          this.challenge = data[1];
          if (this.onauth) {
            this.auth(this.onauth).catch((err) => {
              if (!(err instanceof SendingOnClosedConnection2)) {
                throw err;
              }
            });
          }
          return;
        }
        default: {
          const so = this.openSubs.get(data[1]);
          so?.oncustom?.(data);
          return;
        }
      }
    } catch (err) {
      try {
        const [_, __, event] = JSON.parse(json);
        console.warn(`[nostr] relay ${this.url} error processing message:`, err, event);
      } catch (_) {
        console.warn(`[nostr] relay ${this.url} error processing message:`, err);
      }
      return;
    }
  }
};
var Subscription2 = class {
  relay;
  id;
  lastEmitted;
  closed = false;
  eosed = false;
  filters;
  alreadyHaveEvent;
  receivedEvent;
  onevent;
  oninvalidevent;
  oneose;
  onclose;
  oncustom;
  eoseTimeout;
  eoseTimeoutHandle;
  constructor(relay, id, filters2, params) {
    if (filters2.length === 0)
      throw new Error("subscription can't be created with zero filters");
    this.relay = relay;
    this.filters = filters2;
    this.id = id;
    this.alreadyHaveEvent = params.alreadyHaveEvent;
    this.receivedEvent = params.receivedEvent;
    this.eoseTimeout = params.eoseTimeout || relay.baseEoseTimeout;
    this.oneose = params.oneose;
    this.onclose = params.onclose;
    this.oninvalidevent = params.oninvalidevent;
    this.onevent = params.onevent || ((event) => {
      console.warn(
        `onevent() callback not defined for subscription '${this.id}' in relay ${this.relay.url}. event received:`,
        event
      );
    });
  }
  fire() {
    this.relay.send('["REQ","' + this.id + '",' + JSON.stringify(this.filters).substring(1));
    this.eoseTimeoutHandle = setTimeout(this.receivedEose.bind(this), this.eoseTimeout);
  }
  receivedEose() {
    if (this.eosed)
      return;
    clearTimeout(this.eoseTimeoutHandle);
    this.eosed = true;
    this.oneose?.();
  }
  close(reason = "closed by caller") {
    if (!this.closed && this.relay.connected) {
      try {
        this.relay.send('["CLOSE",' + JSON.stringify(this.id) + "]");
      } catch (err) {
        if (err instanceof SendingOnClosedConnection2) {
        } else {
          throw err;
        }
      }
      this.closed = true;
    }
    this.relay.openSubs.delete(this.id);
    if (!this.id.startsWith("<forced-ping>")) {
      this.relay.ongoingOperations--;
      if (this.relay.ongoingOperations === 0) {
        this.relay.idleSince = Date.now();
        this.relay.scheduleIdleClose();
      }
    }
    this.onclose?.(reason);
  }
};
var M2 = 256;
var HLL_HEX_LENGTH2 = M2 * 2;
var utf8Encoder23 = new TextEncoder();
function getCountManyFilter2(target, directive) {
  switch (directive) {
    case "reactions":
      return { "#e": [target], kinds: [7] };
    case "reposts":
      return { "#e": [target], kinds: [6] };
    case "quotes":
      return { "#q": [target], kinds: [1, 1111] };
    case "replies":
      return { "#e": [target], kinds: [1] };
    case "comments":
      return { "#E": [target], kinds: [1111] };
    case "followers":
      return { "#p": [target], kinds: [3] };
  }
}
function newHll2() {
  return new Uint8Array(M2);
}
function hllDecode2(hex) {
  if (hex.length !== HLL_HEX_LENGTH2 || !/^[0-9a-f]+$/.test(hex))
    return void 0;
  const registers = new Uint8Array(M2);
  for (let i22 = 0; i22 < M2; i22++) {
    registers[i22] = parseInt(hex.slice(i22 * 2, i22 * 2 + 2), 16);
  }
  return registers;
}
function hllEncode2(registers) {
  if (registers.length !== M2)
    throw new Error(`invalid number of registers ${registers.length}`);
  let hex = "";
  for (let i22 = 0; i22 < M2; i22++) {
    hex += registers[i22].toString(16).padStart(2, "0");
  }
  return hex;
}
function mergeHll2(target, source) {
  if (target.length === 0)
    target = newHll2();
  if (target.length !== M2)
    throw new Error(`invalid number of registers ${target.length}`);
  if (source.length !== M2)
    throw new Error(`invalid number of registers ${source.length}`);
  for (let i22 = 0; i22 < M2; i22++) {
    if (source[i22] > target[i22])
      target[i22] = source[i22];
  }
  return target;
}
var AbstractSimplePool2 = class {
  relays = /* @__PURE__ */ new Map();
  seenOn = /* @__PURE__ */ new Map();
  trackRelays = false;
  verifyEvent;
  enablePing;
  enableReconnect;
  idleTimeout = 2e4;
  automaticallyAuth;
  onRelayConnectionFailure;
  onRelayConnectionSuccess;
  allowConnectingToRelay;
  maxWaitForConnection;
  _WebSocket;
  constructor(opts) {
    this.verifyEvent = opts.verifyEvent;
    this._WebSocket = opts.websocketImplementation;
    this.enablePing = opts.enablePing;
    this.enableReconnect = opts.enableReconnect || false;
    if (opts.idleTimeout)
      this.idleTimeout = opts.idleTimeout;
    this.automaticallyAuth = opts.automaticallyAuth;
    this.onRelayConnectionFailure = opts.onRelayConnectionFailure;
    this.onRelayConnectionSuccess = opts.onRelayConnectionSuccess;
    this.allowConnectingToRelay = opts.allowConnectingToRelay;
    this.maxWaitForConnection = opts.maxWaitForConnection || 3e3;
  }
  async ensureRelay(url, params) {
    url = normalizeURL2(url);
    let relay = this.relays.get(url);
    if (!relay) {
      relay = new AbstractRelay2(url, {
        verifyEvent: this.verifyEvent,
        websocketImplementation: this._WebSocket,
        enablePing: this.enablePing,
        enableReconnect: this.enableReconnect,
        idleTimeout: this.idleTimeout
      });
      relay.onclose = () => {
        this.relays.delete(url);
      };
      this.relays.set(url, relay);
    }
    if (this.automaticallyAuth) {
      const authSignerFn = this.automaticallyAuth(url);
      if (authSignerFn) {
        relay.onauth = authSignerFn;
      }
    }
    try {
      await relay.connect({
        timeout: params?.connectionTimeout,
        abort: params?.abort
      });
    } catch (err) {
      this.relays.delete(url);
      throw err;
    }
    return relay;
  }
  close(relays) {
    relays.map(normalizeURL2).forEach((url) => {
      this.relays.get(url)?.close();
      this.relays.delete(url);
    });
  }
  subscribe(relays, filter, params) {
    const request = [];
    const uniqUrls = [];
    for (let i22 = 0; i22 < relays.length; i22++) {
      const url = normalizeURL2(relays[i22]);
      if (!request.find((r) => r.url === url)) {
        if (uniqUrls.indexOf(url) === -1) {
          uniqUrls.push(url);
          request.push({ url, filter });
        }
      }
    }
    return this.subscribeMap(request, params);
  }
  subscribeMany(relays, filter, params) {
    return this.subscribe(relays, filter, params);
  }
  subscribeMap(requests, params) {
    const grouped = /* @__PURE__ */ new Map();
    for (const req of requests) {
      const { url, filter } = req;
      if (!grouped.has(url))
        grouped.set(url, []);
      grouped.get(url).push(filter);
    }
    const groupedRequests = Array.from(grouped.entries()).map(([url, filters2]) => ({ url, filters: filters2 }));
    if (this.trackRelays) {
      params.receivedEvent = (relay, id) => {
        let set = this.seenOn.get(id);
        if (!set) {
          set = /* @__PURE__ */ new Set();
          this.seenOn.set(id, set);
        }
        set.add(relay);
      };
    }
    const _knownIds = /* @__PURE__ */ new Set();
    const subs = [];
    const eosesReceived = [];
    let handleEose = (i22) => {
      if (eosesReceived[i22])
        return;
      eosesReceived[i22] = true;
      if (eosesReceived.filter((a) => a).length === groupedRequests.length) {
        params.oneose?.();
        handleEose = () => {
        };
      }
    };
    const closesReceived = [];
    let handleClose = (i22, url, reason) => {
      if (closesReceived[i22])
        return;
      handleEose(i22);
      closesReceived[i22] = { url, reason };
      if (closesReceived.filter((a) => a).length === groupedRequests.length) {
        params.onclose?.(closesReceived);
        handleClose = () => {
        };
      }
    };
    const localAlreadyHaveEventHandler = (id) => {
      if (params.alreadyHaveEvent?.(id)) {
        return true;
      }
      const have = _knownIds.has(id);
      _knownIds.add(id);
      return have;
    };
    const allOpened = Promise.all(
      groupedRequests.map(async ({ url, filters: filters2 }, i22) => {
        if (this.allowConnectingToRelay?.(url, ["read", filters2]) === false) {
          handleClose(i22, url, "connection skipped by allowConnectingToRelay");
          return;
        }
        let relay;
        try {
          relay = await this.ensureRelay(url, {
            connectionTimeout: this.maxWaitForConnection < (params.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
            abort: params.abort
          });
        } catch (err) {
          this.onRelayConnectionFailure?.(url);
          handleClose(i22, url, err?.message || String(err));
          return;
        }
        this.onRelayConnectionSuccess?.(url);
        let subscription = relay.subscribe(filters2, {
          ...params,
          oneose: () => handleEose(i22),
          onclose: (reason) => {
            if (reason.startsWith("auth-required: ") && params.onauth) {
              relay.auth(params.onauth).then(() => {
                relay.subscribe(filters2, {
                  ...params,
                  oneose: () => handleEose(i22),
                  onclose: (reason2) => {
                    handleClose(i22, url, reason2);
                  },
                  alreadyHaveEvent: localAlreadyHaveEventHandler,
                  eoseTimeout: params.maxWait,
                  abort: params.abort
                });
              }).catch((err) => {
                handleClose(i22, url, `auth was required and attempted, but failed with: ${err}`);
              });
            } else {
              handleClose(i22, url, reason);
            }
          },
          alreadyHaveEvent: localAlreadyHaveEventHandler,
          eoseTimeout: params.maxWait,
          abort: params.abort
        });
        subs.push(subscription);
      })
    );
    return {
      async close(reason) {
        await allOpened;
        subs.forEach((sub) => {
          sub.close(reason);
        });
      }
    };
  }
  subscribeEose(relays, filter, params) {
    let subcloser;
    subcloser = this.subscribe(relays, filter, {
      ...params,
      oneose() {
        const reason = "closed automatically on eose";
        if (subcloser)
          subcloser.close(reason);
        else
          params.onclose?.(relays.map((url) => ({ url, reason })));
      }
    });
    return subcloser;
  }
  subscribeManyEose(relays, filter, params) {
    return this.subscribeEose(relays, filter, params);
  }
  async querySync(relays, filter, params) {
    return new Promise(async (resolve) => {
      const events = [];
      this.subscribeEose(relays, filter, {
        ...params,
        onevent(event) {
          events.push(event);
        },
        onclose(_) {
          resolve(events);
        }
      });
    });
  }
  async get(relays, filter, params) {
    filter.limit = 1;
    const events = await this.querySync(relays, filter, params);
    events.sort((a, b) => b.created_at - a.created_at);
    return events[0] || null;
  }
  async countMany(relays, target, directive, params) {
    const filter = getCountManyFilter2(target, directive);
    const urls = [];
    for (let i22 = 0; i22 < relays.length; i22++) {
      const url = normalizeURL2(relays[i22]);
      if (urls.indexOf(url) === -1)
        urls.push(url);
    }
    const responses = await Promise.all(
      urls.map(async (url) => {
        if (this.allowConnectingToRelay?.(url, ["read", [filter]]) === false)
          return null;
        let relay;
        try {
          relay = await this.ensureRelay(url, {
            connectionTimeout: this.maxWaitForConnection < (params?.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
            abort: params?.abort
          });
        } catch (err) {
          this.onRelayConnectionFailure?.(url);
          return null;
        }
        this.onRelayConnectionSuccess?.(url);
        return relay.countWithHLL([filter], { id: params?.id }).catch(() => null);
      })
    );
    let count = 0;
    let hll;
    for (const response of responses) {
      if (!response)
        continue;
      if (response.count > count)
        count = response.count;
      if (!response.hll || response.hll.length !== 512)
        continue;
      const registers = hllDecode2(response.hll);
      if (!registers)
        continue;
      hll = mergeHll2(hll || new Uint8Array(0), registers);
    }
    return hll ? { count, hll: hllEncode2(hll) } : { count };
  }
  publish(relays, event, params) {
    return relays.map(normalizeURL2).map(async (url, i22, arr) => {
      if (arr.indexOf(url) !== i22) {
        return Promise.reject("duplicate url");
      }
      if (this.allowConnectingToRelay?.(url, ["write", event]) === false) {
        return Promise.reject("connection skipped by allowConnectingToRelay");
      }
      let r;
      try {
        r = await this.ensureRelay(url, {
          connectionTimeout: this.maxWaitForConnection < (params?.maxWait || 0) ? Math.max(params.maxWait * 0.8, params.maxWait - 1e3) : this.maxWaitForConnection,
          abort: params?.abort
        });
      } catch (err) {
        this.onRelayConnectionFailure?.(url);
        return Promise.reject("connection failure: " + String(err));
      }
      return r.publish(event).catch(async (err) => {
        if (err instanceof Error && err.message.startsWith("auth-required: ") && params?.onauth) {
          await r.auth(params.onauth);
          return r.publish(event);
        }
        throw err;
      }).then((reason) => {
        if (this.trackRelays) {
          let set = this.seenOn.get(event.id);
          if (!set) {
            set = /* @__PURE__ */ new Set();
            this.seenOn.set(event.id, set);
          }
          set.add(r);
        }
        return reason;
      });
    });
  }
  listConnectionStatus() {
    const map = /* @__PURE__ */ new Map();
    this.relays.forEach((relay, url) => map.set(url, relay.connected));
    return map;
  }
  destroy() {
    this.relays.forEach((conn) => conn.close());
    this.relays = /* @__PURE__ */ new Map();
  }
  pruneIdleRelays(idleThresholdMs = 1e4) {
    const prunedUrls = [];
    for (const [url, relay] of this.relays) {
      if (relay.idleSince && Date.now() - relay.idleSince >= idleThresholdMs) {
        this.relays.delete(url);
        prunedUrls.push(url);
        relay.close();
      }
    }
    return prunedUrls;
  }
};
var _WebSocket2;
try {
  _WebSocket2 = WebSocket;
} catch {
}
var SimplePool2 = class extends AbstractSimplePool2 {
  constructor(options) {
    super({ verifyEvent: verifyEvent3, websocketImplementation: _WebSocket2, maxWaitForConnection: 3e3, ...options });
  }
};
var _fetch2;
try {
  _fetch2 = fetch;
} catch {
}
var BUNKER_REGEX = /^bunker:\/\/([0-9a-f]{64})\??([?\/\w:.=&%-]*)$/;
async function parseBunkerInput(input) {
  let match = input.match(BUNKER_REGEX);
  if (match) {
    try {
      const pubkey = match[1];
      const qs = new URLSearchParams(match[2]);
      return {
        pubkey,
        relays: qs.getAll("relay"),
        secret: qs.get("secret")
      };
    } catch (_err) {
    }
  }
  return queryBunkerProfile(input);
}
async function queryBunkerProfile(nip05) {
  const match = nip05.match(NIP05_REGEX);
  if (!match)
    return null;
  const [_, name = "_", domain] = match;
  try {
    const url = `https://${domain}/.well-known/nostr.json?name=${name}`;
    const res = await (await _fetch2(url, { redirect: "error" })).json();
    let pubkey = res.names[name];
    let relays = res.nip46[pubkey] || [];
    return { pubkey, relays, secret: null };
  } catch (_err) {
    return null;
  }
}
var BunkerSigner = class {
  params;
  pool;
  subCloser;
  isOpen;
  serial;
  idPrefix;
  listeners;
  waitingForAuth;
  secretKey;
  conversationKey;
  bp;
  cachedPubKey;
  constructor(clientSecretKey, params) {
    this.params = params;
    this.pool = params.pool || new SimplePool2();
    this.secretKey = clientSecretKey;
    this.isOpen = false;
    this.idPrefix = Math.random().toString(36).substring(7);
    this.serial = 0;
    this.listeners = {};
    this.waitingForAuth = {};
  }
  static fromBunker(clientSecretKey, bp, params = {}) {
    if (bp.relays.length === 0) {
      throw new Error("no relays specified for this bunker");
    }
    const signer = new BunkerSigner(clientSecretKey, params);
    signer.conversationKey = getConversationKey2(clientSecretKey, bp.pubkey);
    signer.bp = bp;
    signer.setupSubscription();
    return signer;
  }
  static async fromURI(clientSecretKey, connectionURI, bunkerParams = {}, maxWaitOrAbort = 3e5) {
    const uri = new URL(connectionURI);
    const secret = uri.searchParams.get("secret");
    if (!secret) {
      throw new Error("nostrconnect:// URI has no secret");
    }
    const signer = new BunkerSigner(clientSecretKey, bunkerParams);
    const clientPubkey = getPublicKey3(clientSecretKey);
    return new Promise((resolve, reject) => {
      let success = false;
      const sub = signer.pool.subscribe(
        uri.searchParams.getAll("relay"),
        {
          kinds: [NostrConnect],
          "#p": [clientPubkey],
          limit: 0
        },
        {
          onevent: async (event) => {
            try {
              const tempConvKey = getConversationKey2(clientSecretKey, event.pubkey);
              const decryptedContent = decrypt4(event.content, tempConvKey);
              const response = JSON.parse(decryptedContent);
              if (response.result === secret) {
                sub.close();
                signer.bp = {
                  pubkey: event.pubkey,
                  relays: uri.searchParams.getAll("relay"),
                  secret
                };
                signer.conversationKey = getConversationKey2(clientSecretKey, event.pubkey);
                signer.setupSubscription();
                success = true;
                if (!bunkerParams.skipSwitchRelays) {
                  await Promise.race([new Promise((resolve2) => setTimeout(resolve2, 1e3)), signer.switchRelays()]);
                }
                resolve(signer);
              }
            } catch (e) {
              console.warn("failed to process potential connection event", e);
            }
          },
          onclose: () => {
            if (!success)
              reject(new Error("subscription closed before connection was established."));
          },
          maxWait: typeof maxWaitOrAbort === "number" ? maxWaitOrAbort : void 0,
          abort: typeof maxWaitOrAbort !== "number" ? maxWaitOrAbort : void 0
        }
      );
    });
  }
  setupSubscription() {
    const listeners = this.listeners;
    const waitingForAuth = this.waitingForAuth;
    const convKey = this.conversationKey;
    this.subCloser = this.pool.subscribe(
      this.bp.relays,
      {
        kinds: [NostrConnect],
        authors: [this.bp.pubkey],
        "#p": [getPublicKey3(this.secretKey)],
        limit: 0
      },
      {
        onevent: async (event) => {
          const o = JSON.parse(decrypt4(event.content, convKey));
          const { id, result, error } = o;
          if (result === "auth_url" && waitingForAuth[id]) {
            delete waitingForAuth[id];
            if (this.params.onauth) {
              this.params.onauth(error);
            } else {
              console.warn(
                `nostr-tools/nip46: remote signer ${this.bp.pubkey} tried to send an "auth_url"='${error}' but there was no onauth() callback configured.`
              );
            }
            return;
          }
          let handler = listeners[id];
          if (handler) {
            if (error)
              handler.reject(error);
            else if (result)
              handler.resolve(result);
            delete listeners[id];
          }
        },
        onclose: () => {
          this.subCloser = void 0;
        }
      }
    );
    this.isOpen = true;
  }
  async switchRelays() {
    try {
      const switchResp = await this.sendRequest("switch_relays", []);
      let relays = JSON.parse(switchResp);
      if (!relays)
        return false;
      if (JSON.stringify(relays.sort()) === JSON.stringify(this.bp.relays))
        return false;
      this.bp.relays = relays;
      let previousCloser = this.subCloser;
      setTimeout(() => {
        previousCloser.close();
      }, 5e3);
      this.subCloser = void 0;
      this.setupSubscription();
      return true;
    } catch {
      return false;
    }
  }
  async close() {
    this.isOpen = false;
    this.subCloser?.close();
    this.subCloser = void 0;
  }
  async sendRequest(method, params) {
    return new Promise(async (resolve, reject) => {
      try {
        if (!this.isOpen)
          throw new Error("this signer is not open anymore, create a new one");
        if (!this.subCloser)
          this.setupSubscription();
        this.serial++;
        const id = `${this.idPrefix}-${this.serial}`;
        const encryptedContent = encrypt4(JSON.stringify({ id, method, params }), this.conversationKey);
        const verifiedEvent = finalizeEvent3(
          {
            kind: NostrConnect,
            tags: [["p", this.bp.pubkey]],
            content: encryptedContent,
            created_at: Math.floor(Date.now() / 1e3)
          },
          this.secretKey
        );
        this.listeners[id] = { resolve, reject };
        this.waitingForAuth[id] = true;
        await Promise.any(this.pool.publish(this.bp.relays, verifiedEvent));
      } catch (err) {
        reject(err);
      }
    });
  }
  async ping() {
    let resp = await this.sendRequest("ping", []);
    if (resp !== "pong")
      throw new Error(`result is not pong: ${resp}`);
  }
  async connect(clientMetadata) {
    const params = [this.bp.pubkey, this.bp.secret || ""];
    if (clientMetadata) {
      params.push("");
      params.push(JSON.stringify(clientMetadata));
    }
    await this.sendRequest("connect", params);
  }
  async logout() {
    let resp = await this.sendRequest("logout", []);
    if (resp !== "ack")
      throw new Error(`result is not ack: ${resp}`);
    await this.close();
  }
  async getPublicKey() {
    if (!this.cachedPubKey) {
      this.cachedPubKey = await this.sendRequest("get_public_key", []);
    }
    return this.cachedPubKey;
  }
  async signEvent(event) {
    let resp = await this.sendRequest("sign_event", [JSON.stringify(event)]);
    let signed = JSON.parse(resp);
    if (verifyEvent3(signed)) {
      return signed;
    } else {
      throw new Error(`event returned from bunker is improperly signed: ${JSON.stringify(signed)}`);
    }
  }
  async nip04Encrypt(thirdPartyPubkey, plaintext) {
    return await this.sendRequest("nip04_encrypt", [thirdPartyPubkey, plaintext]);
  }
  async nip04Decrypt(thirdPartyPubkey, ciphertext) {
    return await this.sendRequest("nip04_decrypt", [thirdPartyPubkey, ciphertext]);
  }
  async nip44Encrypt(thirdPartyPubkey, plaintext) {
    return await this.sendRequest("nip44_encrypt", [thirdPartyPubkey, plaintext]);
  }
  async nip44Decrypt(thirdPartyPubkey, ciphertext) {
    return await this.sendRequest("nip44_decrypt", [thirdPartyPubkey, ciphertext]);
  }
};

// src/connections.js
function parseConnectionString(value) {
  const u = new URL(value);
  if (u.protocol !== "nostr+walletconnect:" || u.username || u.password) throw Error("Use a nostr+walletconnect:// connection link.");
  return { pubkey: u.hostname, secret: u.searchParams.get("secret"), relays: u.searchParams.getAll("relay") };
}
async function deadline(p, ms = 2e4) {
  let t;
  try {
    return await Promise.race([p, new Promise((_, reject) => {
      t = setTimeout(() => reject(Error("Connection timed out. Check your service and try again.")), ms);
    })]);
  } finally {
    clearTimeout(t);
  }
}
async function connectBunker(uri, onauth) {
  if (!uri.startsWith("bunker://")) throw Error("Paste a bunker:// connection from your remote signer.");
  const pointer = await parseBunkerInput(uri);
  if (!pointer || !validPubkey(pointer.pubkey)) throw Error("Invalid bunker connection.");
  pointer.relays = relayUrls(pointer.relays);
  const signer = BunkerSigner.fromBunker(generateSecretKey(), pointer, { onauth });
  try {
    await deadline(signer.connect({ name: "Nosternity", url: location.origin }));
    const pubkey = await deadline(signer.getPublicKey());
    if (!validPubkey(pubkey)) throw Error("Signer returned an invalid public key.");
    return { signer, pubkey };
  } catch (e) {
    await signer.close();
    throw e;
  }
}
var Wallet = class {
  constructor(uri) {
    const c = parseConnectionString(uri);
    if (!validPubkey(c.pubkey) || !validPubkey(c.secret)) throw Error("Invalid wallet connection.");
    this.relays = relayUrls(c.relays);
    this.pubkey = c.pubkey;
    this.secret = Uint8Array.from(c.secret.match(/../g), (h) => parseInt(h, 16));
    this.client = getPublicKey(this.secret);
    this.pool = new SimplePool();
    this.methods = [];
    this.pending = /* @__PURE__ */ new Set();
  }
  async connect() {
    const events = await deadline(this.pool.querySync(this.relays, { kinds: [13194], authors: [this.pubkey], limit: 5 }, { maxWait: 1e4 }));
    const info = events.filter((e) => verifyEvent(e)).sort((a, b) => b.created_at - a.created_at)[0];
    if (!info) throw Error("Wallet information was not received. Check its relay and connection.");
    this.methods = info.content.split(/\s+/);
    const enc = info.tags.find((t) => t[0] === "encryption");
    this.mode = enc?.[1]?.includes("nip44_v2") ? "nip44_v2" : "nip04";
    if (enc && !enc[1].includes(this.mode)) throw Error("Wallet encryption is not supported.");
    return this;
  }
  async request(method, params = {}) {
    if (!this.methods.includes(method)) throw Error("This wallet does not permit " + method + ".");
    const plain = JSON.stringify({ method, params });
    const key = this.mode === "nip44_v2" ? getConversationKey(this.secret, this.pubkey) : null;
    const content = key ? encrypt3(plain, key) : await encrypt2(this.secret, this.pubkey, plain);
    const event = finalizeEvent({ kind: 23194, created_at: Math.floor(Date.now() / 1e3), tags: [["p", this.pubkey], ["encryption", this.mode]], content }, this.secret);
    return new Promise((resolve, reject) => {
      let done = false, sub;
      const finish = (err, result) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        sub?.close();
        this.pending.delete(cancel);
        err ? reject(err) : resolve(result);
      };
      const cancel = () => finish(Error("Wallet disconnected."));
      this.pending.add(cancel);
      const timer = setTimeout(() => finish(Error("No wallet response. Check wallet activity before retrying a payment.")), 2e4);
      sub = this.pool.subscribeMany(this.relays, { kinds: [23195], authors: [this.pubkey], "#e": [event.id], "#p": [this.client] }, { onevent: async (reply) => {
        try {
          if (reply.content.length > 1e5 || !verifyEvent(reply)) return;
          const mode = reply.tags.find((t) => t[0] === "encryption")?.[1] || "nip04";
          if (mode !== this.mode) return;
          const text = key ? decrypt3(reply.content, key) : await decrypt2(this.secret, this.pubkey, reply.content);
          const data = JSON.parse(text);
          if (data.result_type !== method) return;
          if (data.error) finish(Error("Wallet declined: " + String(data.error.code || "UNKNOWN")));
          else finish(null, data.result);
        } catch {
          finish(Error("Invalid wallet response."));
        }
      } });
      Promise.any(this.pool.publish(this.relays, event)).catch(() => finish(Error("Could not send the wallet request.")));
    });
  }
  close() {
    for (const cancel of [...this.pending]) cancel();
    this.pool.close(this.relays);
    this.secret.fill(0);
  }
};

// node_modules/nostr-tools/lib/esm/nip19.js
var utf8Decoder6 = new TextDecoder("utf-8");
var utf8Encoder6 = new TextEncoder();
var Bech32MaxSize = 5e3;
function decode(code) {
  let { prefix, words } = bech32.decode(code, Bech32MaxSize);
  let data = new Uint8Array(bech32.fromWords(words));
  switch (prefix) {
    case "nprofile": {
      let tlv = parseTLV(data);
      if (!tlv[0]?.[0])
        throw new Error("missing TLV 0 for nprofile");
      if (tlv[0][0].length !== 32)
        throw new Error("TLV 0 should be 32 bytes");
      return {
        type: "nprofile",
        data: {
          pubkey: bytesToHex(tlv[0][0]),
          relays: tlv[1] ? tlv[1].map((d) => utf8Decoder6.decode(d)) : []
        }
      };
    }
    case "nevent": {
      let tlv = parseTLV(data);
      if (!tlv[0]?.[0])
        throw new Error("missing TLV 0 for nevent");
      if (tlv[0][0].length !== 32)
        throw new Error("TLV 0 should be 32 bytes");
      if (tlv[2] && tlv[2][0].length !== 32)
        throw new Error("TLV 2 should be 32 bytes");
      if (tlv[3] && tlv[3][0].length !== 4)
        throw new Error("TLV 3 should be 4 bytes");
      return {
        type: "nevent",
        data: {
          id: bytesToHex(tlv[0][0]),
          relays: tlv[1] ? tlv[1].map((d) => utf8Decoder6.decode(d)) : [],
          author: tlv[2]?.[0] ? bytesToHex(tlv[2][0]) : void 0,
          kind: tlv[3]?.[0] ? parseInt(bytesToHex(tlv[3][0]), 16) : void 0
        }
      };
    }
    case "naddr": {
      let tlv = parseTLV(data);
      if (!tlv[0]?.[0])
        throw new Error("missing TLV 0 for naddr");
      if (!tlv[2]?.[0])
        throw new Error("missing TLV 2 for naddr");
      if (tlv[2][0].length !== 32)
        throw new Error("TLV 2 should be 32 bytes");
      if (!tlv[3]?.[0])
        throw new Error("missing TLV 3 for naddr");
      if (tlv[3][0].length !== 4)
        throw new Error("TLV 3 should be 4 bytes");
      return {
        type: "naddr",
        data: {
          identifier: utf8Decoder6.decode(tlv[0][0]),
          pubkey: bytesToHex(tlv[2][0]),
          kind: parseInt(bytesToHex(tlv[3][0]), 16),
          relays: tlv[1] ? tlv[1].map((d) => utf8Decoder6.decode(d)) : []
        }
      };
    }
    case "nsec":
      return { type: prefix, data };
    case "npub":
    case "note":
      return { type: prefix, data: bytesToHex(data) };
    default:
      throw new Error(`unknown prefix ${prefix}`);
  }
}
function parseTLV(data) {
  let result = {};
  let rest = data;
  while (rest.length > 0) {
    if (rest.length < 2)
      throw new Error("not enough data to read TLV");
    let t = rest[0];
    let l = rest[1];
    let v = rest.slice(2, 2 + l);
    rest = rest.slice(2 + l);
    if (v.length < l)
      throw new Error(`not enough data to read on TLV ${t}`);
    result[t] = result[t] || [];
    result[t].push(v);
  }
  return result;
}
function npubEncode(hex) {
  return encodeBytes("npub", hexToBytes(hex));
}
function encodeBech32(prefix, data) {
  let words = bech32.toWords(data);
  return bech32.encode(prefix, words, Bech32MaxSize);
}
function encodeBytes(prefix, bytes) {
  return encodeBech32(prefix, bytes);
}

// src/dashboard.js
var $ = (s) => document.querySelector(s);
var brand = {
  name: document.body.dataset.nodeName || "Nosternity",
  title: document.body.dataset.nodeTitle || document.title,
  description: document.body.dataset.nodeDescription || ""
};
var state = {
  page: "explore",
  scope: "global",
  query: "",
  kind: "all",
  session: null,
  damage: null,
  signer: null,
  signerType: "",
  wallet: null,
  balance: null,
  events: [],
  account: null,
  epoch: 0
};
var dialogEpoch = 0;
var pollTimer;
var toastTimer;
var pendingProof = null;
var authBusy = false;
async function authenticating(fn) {
  if (authBusy) throw Error("Wait for the current sign-in to finish.");
  authBusy = true;
  try {
    return await fn();
  } finally {
    authBusy = false;
  }
}
var labels = { explore: "Explore", account: "My feed", saved: "Saved notes", analytics: "Search & index", wallet: "Lightning wallet", signer: "Key & signing", settings: "Connections" };
var messages = {
  account_not_found: "No account exists for this identity yet. Choose Create account and prove your identity again.",
  invalid_proof: "The signature could not be verified. Start a new sign-in.",
  invalid_challenge: "This challenge expired or was already used. Start again.",
  nostr_login_required: "Sign in with Nostr to use this action.",
  damage_login_required: "Sign in to a managed DamageBDD account for this action.",
  origin_rejected: "Open the configured node origin. Ask your operator to check browser_auth_origin.",
  auth_unavailable: "Authentication is unavailable. Check the server configuration or try again.",
  unauthorized: "Your session has expired. Sign in again.",
  rate_limited: "Too many requests. Wait a minute and retry.",
  signup_unavailable: "New accounts are currently unavailable."
};
async function api(path, body, extra = {}) {
  const response = await fetch(path, {
    method: body === void 0 ? "GET" : "POST",
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-Nosternity-Auth": "1", "X-Damage-Auth": "1", ...body === void 0 ? {} : { "Content-Type": "application/json" }, ...extra },
    body: body === void 0 ? void 0 : typeof body === "string" ? body : JSON.stringify(body),
    signal: AbortSignal.timeout(2e4)
  });
  let data;
  try {
    data = await response.json();
  } catch {
    throw Error("The server did not return JSON. Check the dashboard deployment.");
  }
  if (!response.ok) {
    const e = Error(messages[data.error] || data.message || String(data.error || "Request failed"));
    e.code = response.status;
    throw e;
  }
  return data;
}
function toast(message) {
  $("#toast").textContent = message;
  $("#toast").style.display = "block";
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $("#toast").style.display = "none", 7e3);
}
function fail(error) {
  const text = error?.message || "This request could not be completed.";
  if ($("#modal").open) $("#modalError").textContent = text;
  else toast(text);
}
function close() {
  if (authBusy) return;
  dialogEpoch++;
  clearTimeout(pollTimer);
  if (pendingProof?.provider !== state.signer) pendingProof?.provider.close?.();
  pendingProof = null;
  $("#modal").close();
  $("#modalBody").replaceChildren();
}
function modal(html) {
  close();
  $("#modalBody").innerHTML = html;
  $("#modalError").textContent = "";
  $("#modal").showModal();
  return dialogEpoch;
}
function short(key) {
  return key ? key.slice(0, 8) + "\u2026" + key.slice(-6) : "Not connected";
}
function intent() {
  return $("#authIntent")?.value || "login";
}
function publicKey(input) {
  const s = input.trim();
  if (validPubkey(s)) return s;
  if (s.startsWith("npub1")) {
    const n = decode(s);
    if (n.type === "npub") return n.data;
  }
  throw Error("Enter a full Nostr public key or npub.");
}
function prefs() {
  return state.account?.preferences || { spam: true, duplicates: true, muted: [], words: [], bookmarks: [] };
}
async function restore() {
  const epoch = state.epoch;
  const results = await Promise.allSettled([api("/api/nosternity/auth/session"), api("/accounts/session")]);
  if (epoch !== state.epoch) return;
  for (let i4 = 0; i4 < results.length; i4++) {
    const r = results[i4];
    const key = i4 === 0 ? "session" : "damage";
    if (r.status === "fulfilled") state[key] = r.value;
    else if (r.reason.code === 401) state[key] = null;
    else throw r.reason;
  }
  const account = state.session ? await api("/api/nosternity/account") : null;
  if (epoch !== state.epoch) return;
  state.account = account;
  chrome();
}
function chrome() {
  const s = state.session;
  $(".headeractions button").innerHTML = s ? "Your account \u2197" : "Connect account \u2197";
  $("#mode").textContent = s ? "\u25CF " + (s.provider === "nostr" ? "Nostr connected" : s.provider === "lightning" ? "Lightning identity" : "DamageBDD identity") : "\u25CB Guest";
  $("#savedCount").textContent = prefs().bookmarks.length;
  const p = $(".profile");
  p.innerHTML = '<span class="avatar">' + (s ? "\u25CE" : "\u2197") + "</span><span>" + escapeHTML(s ? short(s.subject) : "Make yourself at home") + "<small>" + escapeHTML(s ? s.provider + " identity" : "Connect your account") + "</small></span>";
}
async function fragment(name) {
  const r = await fetch("/dashboard/fragments/" + name, { credentials: "same-origin" });
  if (!r.ok) throw Error("Dashboard fragment is unavailable. Deploy templates and assets together.");
  return r.text();
}
async function navigate(page) {
  if (!labels[page]) return;
  const epoch = ++state.epoch;
  state.page = page;
  location.hash = page;
  $("#crumb").textContent = labels[page];
  document.querySelectorAll("nav button").forEach((b) => b.classList.toggle("active", b.dataset.page === page));
  const titles = {
    explore: ["", brand.description],
    account: ["Your voice.<br>Your <em>community.</em>", "Your public notes and the people you choose to follow."],
    saved: ["Good ideas.<br>Worth <em>keeping.</em>", "Bookmarks saved to your " + brand.name + " account."],
    analytics: ["A clearer view.<br>Of your <em>network.</em>", "Real index counts and dashboard activity since this node started."],
    wallet: ["Small payments.<br>Real <em>possibilities.</em>", "A wallet connection is separate from your login."],
    signer: ["Your keys.<br>Your <em>say.</em>", "Sign with your browser extension or remote nsecBunker."],
    settings: ["Your connections.<br>Your <em>choice.</em>", "Your accounts and permissions, clearly separated."]
  };
  if (page === "explore") $("#title").textContent = brand.title;
  else $("#title").innerHTML = titles[page][0];
  $("#subtitle").textContent = titles[page][1];
  if (["explore", "account", "saved"].includes(page)) {
    state.scope = page === "account" ? "account" : page === "saved" ? "saved" : state.scope === "saved" ? "global" : state.scope;
    const html = await fragment("feed");
    if (epoch !== state.epoch) return;
    $("#content").innerHTML = html;
    $("#search").value = state.query;
    $("#kind").value = state.kind;
    await loadFeed(epoch);
  } else if (page === "settings") {
    settings();
  } else {
    const html = await fragment(page);
    if (epoch !== state.epoch) return;
    $("#content").innerHTML = html;
    if (page === "analytics") await metrics(epoch);
    if (page === "wallet") walletView();
    if (page === "signer") signerView();
  }
  chrome();
}
function blank(title, text) {
  return '<div class="empty"><span>\u2733</span><h2>' + escapeHTML(title) + "</h2><p>" + escapeHTML(text) + "</p></div>";
}
function post(e) {
  const name = short(e.pubkey);
  const date = new Date(e.created_at * 1e3);
  const dateText = Number.isFinite(date.getTime()) ? date.toLocaleString() : "Unknown time";
  return '<article class="post"><div class="posthead"><span class="avatar">' + escapeHTML(e.pubkey.slice(0, 2).toUpperCase()) + "</span><div><b>" + escapeHTML(name) + "</b><small>Signed Nostr event</small></div><time>" + escapeHTML(dateText) + "</time></div><p>" + escapeHTML(e.content) + '</p><div class="tags">' + (e.tags || []).filter((t) => t[0] === "t").slice(0, 5).map((t) => "#" + escapeHTML(t[1])).join(" &nbsp; ") + '</div><div class="postactions"><button data-action="details" data-id="' + e.id + '">\u2197 View event</button><button data-action="mute" data-id="' + e.id + '">\u2298 Mute</button><button data-action="bookmark" data-id="' + e.id + '">' + (prefs().bookmarks.includes(e.id) ? "\u25A3 Saved" : "\u25B1 Save") + "</button></div></article>";
}
async function loadFeed(epoch = state.epoch) {
  $("#posts").innerHTML = blank("Finding your next discovery\u2026", "Loading notes from this relay.");
  try {
    const r = await api("/api/nosternity/feed", { scope: state.scope, query: state.query, kind: state.kind === "all" ? "all" : Number(state.kind), limit: 50 });
    if (epoch !== state.epoch) return;
    state.events = r.results.map((r2) => r2.event).filter((e) => {
      try {
        return verifyEvent(e);
      } catch {
        return false;
      }
    });
    $("#posts").innerHTML = state.events.length ? state.events.map(post).join("") : blank("Nothing here yet", state.scope === "following" ? "The relay needs your contact list and notes from the people you follow." : "Try another search, refresh, or publish your first note.");
    $("#filterSummary").textContent = (prefs().spam ? "Spam filtering on" : "Spam filtering off") + " \xB7 " + r.hidden + " hidden from the candidate batch";
    $("#feedSummary").textContent = state.events.length + " shown \xB7 Up to 50 candidate events";
    document.querySelectorAll("[data-scope]").forEach((b) => b.classList.toggle("active", b.dataset.scope === state.scope));
    const m = await api("/api/nosternity/analytics");
    if (epoch !== state.epoch) return;
    $("#snapshot").innerHTML = "<div>Stored events <b>" + escapeHTML(m.relay.events) + "</b></div><div>Text index <b>" + escapeHTML(m.relay.index) + "</b></div><div>Capacity <b>" + escapeHTML(m.relay.max_events) + "</b></div>";
  } catch (e) {
    if (epoch === state.epoch) {
      $("#posts").innerHTML = blank("We couldn\u2019t load this feed", e.message);
      $("#filterSummary").textContent = "Feed unavailable";
    }
  }
}
async function metrics(epoch) {
  const m = await api("/api/nosternity/analytics");
  if (epoch !== state.epoch) return;
  const a = m.relay, d = m.dashboard;
  $("#metrics").innerHTML = [["Stored events", a.events], ["Indexed records", a.index], ["Active subscriptions", a.subscriptions], ["Dashboard searches", d.searches], ["Filtered candidates", d.hidden], ["Capacity", a.max_events]].map(([name, value]) => '<div class="card"><span class="caption">' + escapeHTML(name) + '</span><strong class="big">' + escapeHTML(value) + "</strong></div>").join("") + '<div class="card wide"><h2>Relay state</h2><p>Archive hydration ' + (a.hydrated ? "complete or disabled" : "in progress") + ". Dashboard metrics cover requests on this node since " + escapeHTML(new Date(d.since * 1e3).toLocaleString()) + ". They reset when the authentication worker restarts.</p><p>Mean dashboard feed/search time: " + (d.requests ? Math.round(d.duration_ms / d.requests) : 0) + ' ms. Counts are not whole-network totals.</p><button data-action="refresh">Refresh \u21BB</button></div>';
}
function walletView() {
  if (!$("#walletStatus")) return;
  $("#walletStatus").textContent = state.wallet ? "NWC connected" : "Not connected";
  $("#walletBalance").textContent = state.balance === null ? "\u2014" : state.balance.toLocaleString();
  $("#damageStatus").textContent = state.damage ? "Signed in as " + short(state.damage.address) + " (" + state.damage.mode + ")." : "No DamageBDD session connected.";
}
function signerView() {
  if ($("#identity")) $("#identity").textContent = state.session?.provider === "nostr" ? npubEncode(state.session.subject) + (state.signer ? " \xB7 " + state.signerType : " \xB7 reconnect your signer to publish") : "No Nostr session. Connect your signer to sign in or create an account.";
}
function settings() {
  const s = state.session;
  $("#content").innerHTML = '<div class="split"><div class="card"><h2>Your ' + escapeHTML(brand.name) + " account</h2><p>" + escapeHTML(s ? s.provider + " \xB7 " + short(s.subject) : "Exploring as a guest") + '</p><p>One proved identity per account. Signing in with another provider switches accounts; no identity is silently linked.</p><button class="dark" data-action="login">Sign in / create account</button><button data-action="filters">Feed preferences</button><button data-action="signout">Sign out</button></div><div class="card"><h2>Connected services</h2><p>This dashboard uses the node listener at ' + escapeHTML(location.origin) + '. DamageBDD authentication and NWC routes are mounted on this origin.</p><button data-action="damageLogin">Connect DamageBDD</button><button data-action="nwc">Connect Lightning wallet</button><p>No private keys, bearer tokens, or wallet connection secrets are stored in localStorage.</p></div></div>';
}
function authDialog() {
  modal($("#authTemplate").innerHTML);
}
async function prepareNostr(provider, type, wantedIntent) {
  const startingEpoch = dialogEpoch;
  const expected = await deadline(provider.getPublicKey());
  if (startingEpoch !== dialogEpoch) {
    await provider.close?.();
    return;
  }
  if (!validPubkey(expected)) throw Error("Signer returned an invalid public key.");
  const challenge2 = await api("/api/nosternity/auth/nostr/challenge", { intent: wantedIntent });
  if (startingEpoch !== dialogEpoch) {
    await provider.close?.();
    return;
  }
  const epoch = modal("<h2>Review your " + (wantedIntent === "signup" ? "account creation" : "sign-in") + "</h2><p>You are proving ownership of this Nostr identity at <b>" + escapeHTML(location.origin) + '</b>.</p><p class="mono">' + escapeHTML(npubEncode(expected)) + '</p><p>This one-use HTTP authentication signature does not publish a note or authorize a payment.</p><button class="dark" data-action="signProof">Approve & sign challenge</button>');
  pendingProof = { provider, type, expected, challenge: challenge2, epoch };
}
async function signProof() {
  const p = pendingProof;
  if (!p) throw Error("Start a new sign-in.");
  const event = await deadline(p.provider.signEvent({ ...p.challenge.event, created_at: Math.floor(Date.now() / 1e3) }));
  if (p.epoch !== dialogEpoch) return;
  if (!verifyEvent(event) || event.pubkey !== p.expected) throw Error("Signer identity changed. Start again.");
  const s = await authenticating(() => api("/api/nosternity/auth/nostr/verify", p.challenge.payload, { Authorization: "Nostr " + btoa(JSON.stringify(event)) }));
  const previous = state.signer;
  state.signer = p.provider;
  state.signerType = p.type;
  state.session = s;
  pendingProof = null;
  if (previous !== state.signer) await previous?.close?.();
  close();
  await restore();
  await navigate("account");
  toast("Nostr account connected.");
}
async function nostrLogin() {
  const wanted = intent();
  if (!window.nostr?.getPublicKey) throw Error("Install or unlock a NIP-07 browser signer, or choose nsecBunker.");
  await prepareNostr(window.nostr, "Browser signer", wanted);
}
function bunker() {
  const wanted = intent();
  modal('<h2>Connect nsecBunker</h2><p>Paste a bunker:// link from your remote signer. Keep its secret private.</p><form id="bunkerForm" data-intent="' + wanted + '"><label for="bunkerUri">Connection link</label><input id="bunkerUri" type="password" autocomplete="off" required><button class="dark">Connect remote signer</button></form><div id="bunkerApproval"></div>');
}
async function lightning() {
  const wanted = intent();
  const epoch = modal('<h2>Continue with Lightning</h2><p id="lnstatus">Preparing your wallet challenge\u2026</p><div id="lnqr"></div><p id="lnlink"></p><p>No payment is requested. Use a wallet that supports LNURL-auth.</p>');
  const c = await api("/api/nosternity/auth/lightning/challenge", { intent: wanted });
  if (epoch !== dialogEpoch) return;
  $("#lnstatus").textContent = wanted === "signup" ? "Scan to create your Lightning account." : "Scan to sign in with your Lightning identity.";
  new window.QRCode($("#lnqr"), { text: c.lnurl, width: 210, height: 210 });
  if (/^lnurl[0-9a-z]+$/i.test(c.lnurl)) $("#lnlink").innerHTML = '<a href="lightning:' + escapeHTML(c.lnurl) + '">Open wallet \u2197</a>';
  async function poll() {
    if (epoch !== dialogEpoch) return;
    if (Date.now() / 1e3 > c.expires_at) {
      $("#lnstatus").textContent = "Challenge expired. Close this dialog and try again.";
      return;
    }
    try {
      const s = await authenticating(() => api("/api/nosternity/auth/lightning/poll", { challenge_id: c.challenge_id }));
      if (epoch !== dialogEpoch) return;
      if (s.status === "pending") {
        pollTimer = setTimeout(poll, 2500);
        return;
      }
      state.session = s;
      await state.signer?.close?.();
      state.signer = null;
      close();
      await restore();
      await navigate("settings");
      toast("Lightning account connected.");
    } catch (e) {
      fail(e);
    }
  }
  pollTimer = setTimeout(poll, 2500);
}
function damageLogin() {
  const wanted = intent();
  modal('<h2>Your DamageBDD account</h2><p>Sign in to connect DamageBDD services. Your Nostr session stays primary if already connected.</p><form id="damageForm" data-intent="' + wanted + '"><label for="damageMode">Action</label><select id="damageMode"><option value="login">Sign in</option><option value="signup">Create DamageBDD account</option><option value="recovery">Recover account</option></select><label for="email">Email</label><input id="email" type="email" autocomplete="username" required><div id="passwordRow"><label for="password">Password</label><input id="password" type="password" autocomplete="current-password" required></div><button class="dark">Continue</button></form>');
}
async function savePrefs(next) {
  if (!state.session) throw Error("Sign in to save feed preferences.");
  const epoch = state.epoch;
  const account = await api("/api/nosternity/preferences", next);
  if (epoch === state.epoch) state.account = account;
  chrome();
}
function filters() {
  const p = prefs();
  modal('<h2>A little less noise.</h2><p>Simple, reversible filters applied by your server to each loaded batch.</p><form id="filtersForm"><div class="setting"><label for="spam">Filter obvious promotional spam</label><input id="spam" type="checkbox" ' + (p.spam ? "checked" : "") + '></div><div class="setting"><label for="duplicates">Hide repeated text</label><input id="duplicates" type="checkbox" ' + (p.duplicates ? "checked" : "") + '></div><label for="words">Muted words, comma separated</label><input id="words" value="' + escapeHTML(p.words.join(", ")) + '"><p>' + p.muted.length + ' authors muted.</p><button type="button" data-action="unmute">Clear muted authors</button><button class="dark">Save preferences</button></form>');
}
async function ensureSigner() {
  if (state.session?.provider !== "nostr") throw Error(messages.nostr_login_required);
  if (!state.signer) throw Error("Reconnect your browser signer or nsecBunker in Key & signing.");
  const pub = await deadline(state.signer.getPublicKey());
  if (pub !== state.session.subject) throw Error("Your signer identity differs from this session. Sign in again.");
  return pub;
}
async function publish(kind, content, tags = []) {
  const pub = await ensureSigner();
  const e = await deadline(state.signer.signEvent({ kind, content, tags, created_at: Math.floor(Date.now() / 1e3) }));
  if (!verifyEvent(e) || e.pubkey !== pub || e.kind !== kind || e.content !== content || JSON.stringify(e.tags) !== JSON.stringify(tags)) throw Error("Unexpected event returned by signer.");
  const r = await api("/api/nosternity/events", e);
  if (r.accepted !== true) throw Error("Relay did not accept the event.");
  return r;
}
function nwc() {
  modal('<h2>Bring your Lightning wallet.</h2><p>Set your permissions and spending budget in your wallet, then paste its NWC connection here.</p><form id="nwcForm"><label for="nwcUri">Private connection link</label><input id="nwcUri" type="password" autocomplete="off" required placeholder="nostr+walletconnect://\u2026"><button class="dark">Connect wallet</button></form>');
}
async function balance() {
  if (!state.wallet) throw Error("Connect a Lightning wallet first.");
  const r = await state.wallet.request("get_balance");
  if (!Number.isFinite(r?.balance)) throw Error("Invalid wallet balance.");
  state.balance = r.balance / 1e3;
  walletView();
}
function requireWallet() {
  if (!state.wallet) throw Error("Connect a Lightning wallet first.");
}
function requireDamage() {
  if (!state.damage || state.damage.mode !== "custodial") throw Error(messages.damage_login_required);
}
async function sessions() {
  requireDamage();
  const r = await api("/api/nwc/sessions", {});
  modal("<h2>DamageBDD wallet connections</h2>" + (r.sessions || []).map((s) => '<div class="setting"><span class="mono">' + escapeHTML(short(s.client_pubkey)) + '</span><button data-action="revoke" data-key="' + escapeHTML(s.client_pubkey) + '" ' + (s.revoked ? "disabled" : "") + ">" + (s.revoked ? "Revoked" : "Revoke") + "</button></div>").join(""));
}
var actions = {
  close,
  login: authDialog,
  nostrLogin,
  bunker,
  signProof,
  lightning,
  damageLogin,
  filters,
  nwc,
  balance,
  sessions,
  refresh: () => navigate(state.page),
  compose: async () => {
    await ensureSigner();
    modal('<h2>What\u2019s on your mind?</h2><form id="composeForm"><label for="note">Public note</label><textarea id="note" maxlength="16000" required></textarea><button class="dark">Sign & publish</button></form>');
  },
  profile: async () => {
    await ensureSigner();
    const r = await api("/api/nostr/search", { filters: [{ kinds: [0], authors: [state.session.subject], limit: 1 }] });
    let p = {};
    try {
      p = JSON.parse(r.results[0]?.event.content || "{}");
    } catch {
    }
    modal('<h2>Your Nostr profile</h2><p>Updates are public signed profile events.</p><form id="profileForm"><label for="name">Display name</label><input id="name" maxlength="100" value="' + escapeHTML(p.name || "") + '"><label for="about">About you</label><textarea id="about" maxlength="2000">' + escapeHTML(p.about || "") + '</textarea><button class="dark">Sign & update profile</button></form>');
    $("#profileForm")._profile = p;
  },
  follow: async () => {
    await ensureSigner();
    modal('<h2>Follow someone</h2><form id="followForm"><label for="followKey">Nostr public key or npub</label><input id="followKey" required><p>This updates your contact list from the latest kind-3 event on this relay. Connect the relay holding your full list before adding people.</p><button class="dark">Review contact list</button></form>');
  },
  bookmark: async (el) => {
    const ids = prefs().bookmarks;
    await savePrefs({ ...prefs(), bookmarks: ids.includes(el.dataset.id) ? ids.filter((x) => x !== el.dataset.id) : [el.dataset.id, ...ids].slice(0, 100) });
    await navigate(state.page);
  },
  mute: async (el) => {
    const e = state.events.find((e2) => e2.id === el.dataset.id);
    if (!e) return;
    await savePrefs({ ...prefs(), muted: [.../* @__PURE__ */ new Set([...prefs().muted, e.pubkey])].slice(0, 200) });
    await navigate(state.page);
  },
  unmute: async () => {
    await savePrefs({ ...prefs(), muted: [] });
    filters();
  },
  details: (el) => {
    const e = state.events.find((e2) => e2.id === el.dataset.id);
    if (e) modal('<h2>Signed event</h2><p>A valid signature proves authorship, not the truth of the content.</p><pre class="mono" style="white-space:pre-wrap;max-height:50vh;overflow:auto">' + escapeHTML(JSON.stringify(e, null, 2)) + "</pre>");
  },
  disconnectWallet: () => {
    state.wallet?.close();
    state.wallet = null;
    state.balance = null;
    walletView();
    toast("Disconnected locally. Revoke the connection in your wallet to remove permission.");
  },
  pay: () => {
    requireWallet();
    modal('<h2>Pay a Lightning invoice</h2><form id="payForm"><label for="invoice">BOLT11 invoice</label><textarea id="invoice" required></textarea><button class="dark">Review payment</button></form>');
  },
  receive: () => {
    requireWallet();
    modal('<h2>Receive sats</h2><form id="receiveForm"><label for="amount">Amount in sats</label><input id="amount" type="number" min="1" max="100000000" required><label for="description">Description</label><input id="description" maxlength="150"><button class="dark">Create invoice</button></form>');
  },
  mint: () => {
    requireDamage();
    modal('<h2>Create a budgeted connection</h2><form id="mintForm"><label for="single">Maximum per payment (sats)</label><input id="single" type="number" min="1" max="100000000" value="1000" required><label for="total">Total budget (sats)</label><input id="total" type="number" min="1" max="100000000" value="10000" required><p>This creates a spend-capable connection using DamageBDD\u2019s configured relays.</p><button class="dark">Create connection</button></form>');
  },
  revoke: (el) => {
    const key = el.dataset.key;
    if (!validPubkey(key)) throw Error("Invalid connection key.");
    modal('<h2>Revoke wallet access?</h2><p class="mono">' + key + '</p><button class="dark" data-action="confirmRevoke" data-key="' + key + '">Confirm revocation</button>');
  },
  confirmRevoke: async (el) => {
    requireDamage();
    const r = await api("/api/nwc/revoke", { client_pubkey: el.dataset.key });
    if (r.revoked !== true) throw Error("Revocation needs a ledger signature in DamageBDD. Access is not yet confirmed revoked.");
    await sessions();
  },
  signout: async () => {
    const results = await authenticating(() => Promise.allSettled([api("/api/nosternity/auth/logout", {}), api("/accounts/session/logout", {})]));
    await state.signer?.close?.();
    state.signer = null;
    actions.disconnectWallet();
    state.session = null;
    state.damage = null;
    state.account = null;
    close();
    chrome();
    await navigate("explore");
    if (results.some((r) => r.status === "rejected")) throw Error("Local connections closed, but server logout was not confirmed. Retry when the service is available.");
    toast("Signed out.");
  }
};
var forms = {
  searchForm: async () => {
    state.query = $("#search").value.trim();
    await navigate(state.page);
  },
  bunkerForm: async (form) => {
    const uri = $("#bunkerUri").value.trim();
    $("#bunkerUri").value = "";
    const epoch = dialogEpoch;
    let result;
    try {
      result = await connectBunker(uri, (url) => {
        try {
          const u = new URL(url);
          if (u.protocol === "https:" && $("#bunkerApproval")) $("#bunkerApproval").innerHTML = '<a href="' + escapeHTML(u.href) + '" target="_blank" rel="noopener noreferrer">Review approval at ' + escapeHTML(u.host) + " \u2197</a>";
        } catch {
        }
      });
      if (epoch !== dialogEpoch) {
        await result.signer.close();
        return;
      }
      await prepareNostr(result.signer, "Remote signer \xB7 NIP-46", form.dataset.intent);
    } catch (e) {
      await result?.signer.close();
      throw e;
    }
  },
  damageForm: async (form) => {
    const mode = $("#damageMode").value, email = $("#email").value.trim(), password = $("#password").value;
    $("#password").value = "";
    const body = mode === "login" ? { username: email, password } : { email };
    const r = await authenticating(() => api("/accounts/" + mode, body));
    if (mode !== "login") {
      modal("<h2>Check your email</h2><p>" + escapeHTML(r.message || "Continue using the confirmation or recovery link sent by DamageBDD.") + '</p><button class="dark" data-action="damageLogin">Back to sign in</button>');
      return;
    }
    state.damage = r;
    if (!state.session) state.session = await authenticating(() => api("/api/nosternity/auth/damage", { intent: form.dataset.intent }));
    close();
    await restore();
    await navigate("settings");
    toast("DamageBDD connected.");
  },
  filtersForm: async () => {
    const p = { ...prefs(), spam: $("#spam").checked, duplicates: $("#duplicates").checked, words: $("#words").value.split(",").map((s) => s.trim()).filter(Boolean) };
    await savePrefs(p);
    close();
    await navigate(state.page);
  },
  composeForm: async () => {
    const text = $("#note").value.trim();
    if (!text || new TextEncoder().encode(text).length > 16e3) throw Error("Enter 1\u201316,000 bytes of text.");
    await publish(1, text);
    close();
    await navigate("account");
    toast("Note accepted by this relay.");
  },
  profileForm: async (form) => {
    const p = { ...form._profile, name: $("#name").value.trim(), about: $("#about").value.trim() };
    await publish(0, JSON.stringify(p));
    close();
    toast("Profile update accepted by this relay.");
  },
  followForm: async () => {
    const key = publicKey($("#followKey").value);
    const r = await api("/api/nostr/search", { filters: [{ kinds: [3], authors: [state.session.subject], limit: 1 }] });
    const prev = r.results[0]?.event;
    const tags = prev?.tags || [];
    if (tags.some((t) => t[0] === "p" && t[1] === key)) throw Error("Already following this key on this relay.");
    if (tags.length >= 255) throw Error("Contact list is at this relay\u2019s tag limit.");
    const next = [...tags, ["p", key]];
    modal("<h2>Update your contact list?</h2><p>Preserves " + tags.filter((t) => t[0] === "p").length + ' contacts from this relay and adds:</p><p class="mono">' + escapeHTML(npubEncode(key)) + '</p><form id="confirmFollow"><button class="dark">Sign & publish contact list</button></form>');
    $("#confirmFollow")._event = { tags: next, content: prev?.content || "" };
  },
  confirmFollow: async (form) => {
    await publish(3, form._event.content, form._event.tags);
    close();
    state.scope = "following";
    await navigate("explore");
  },
  nwcForm: async () => {
    const uri = $("#nwcUri").value.trim();
    $("#nwcUri").value = "";
    const epoch = dialogEpoch;
    let w;
    try {
      w = new Wallet(uri);
      await w.connect();
    } catch (e) {
      w?.close();
      throw e;
    }
    if (epoch !== dialogEpoch) {
      w.close();
      return;
    }
    state.wallet?.close();
    state.wallet = w;
    state.balance = null;
    close();
    await navigate("wallet");
    if (w.methods.includes("get_balance")) await balance();
  },
  payForm: async () => {
    const invoice = $("#invoice").value.trim().replace(/^lightning:/i, "");
    if (!/^ln(bc|tb|bcrt)[0-9a-z]+$/i.test(invoice)) throw Error("Enter a BOLT11 invoice.");
    modal('<h2>Confirm payment</h2><p>Check the invoice and its amount in your wallet. Payment uses this connection\u2019s permissions.</p><p class="mono" style="max-height:180px;overflow:auto">' + escapeHTML(invoice) + '</p><form id="confirmPayment"><div class="row"><input type="checkbox" id="confirmPay" required><label for="confirmPay">I have checked this invoice and want to pay it.</label></div><button class="dark">Pay this invoice</button></form>');
    $("#confirmPayment")._invoice = invoice;
  },
  confirmPayment: async (form) => {
    requireWallet();
    const r = await state.wallet.request("pay_invoice", { invoice: form._invoice });
    if (!r?.preimage) throw Error("No payment proof returned. Check your wallet before retrying.");
    state.balance = null;
    modal('<h2>Payment sent</h2><p>Your wallet returned this proof:</p><p class="mono">' + escapeHTML(r.preimage) + "</p>");
    walletView();
  },
  receiveForm: async () => {
    requireWallet();
    const sats = Number($("#amount").value);
    if (!Number.isSafeInteger(sats) || sats < 1 || sats > 1e8) throw Error("Enter a whole amount from 1 to 100,000,000 sats.");
    const r = await state.wallet.request("make_invoice", { amount: sats * 1e3, description: $("#description").value });
    if (!/^ln(bc|tb|bcrt)[0-9a-z]+$/i.test(r?.invoice)) throw Error("Wallet did not return a valid invoice.");
    modal("<h2>Ready to receive " + sats.toLocaleString() + ' sats</h2><div id="invoiceQr"></div><p class="mono">' + escapeHTML(r.invoice) + "</p><p>Invoice created. Payment has not been confirmed.</p>");
    new window.QRCode($("#invoiceQr"), { text: r.invoice, width: 200, height: 200 });
  },
  mintForm: async () => {
    requireDamage();
    const single = Number($("#single").value), total = Number($("#total").value);
    if (!Number.isSafeInteger(single) || !Number.isSafeInteger(total) || single < 1 || total < single || total > 1e8) throw Error("Total budget must cover the per-payment limit.");
    const r = await api("/api/nwc/mint", { max_single_sat: single, max_total_sat: total });
    if (r.usable !== true || !r.nwc_uri) throw Error("Finish the required ledger registration in DamageBDD first.");
    modal('<h2>Connection created</h2><p>This private link grants wallet access within your budget. It is cleared when you close this dialog.</p><textarea id="mintedUri" readonly aria-label="Private wallet connection"></textarea>');
    $("#mintedUri").value = r.nwc_uri;
  }
};
document.addEventListener("click", async (e) => {
  const el = e.target.closest("button");
  if (!el) return;
  if (authBusy) {
    e.preventDefault();
    return;
  }
  try {
    if (el.dataset.page) {
      if (el.dataset.page === "explore") state.scope = "global";
      close();
      await navigate(el.dataset.page);
    } else if (el.dataset.topic !== void 0) {
      state.query = el.dataset.topic;
      state.scope = "global";
      await navigate("explore");
    } else if (el.dataset.scope) {
      state.scope = el.dataset.scope;
      await navigate("explore");
    } else if (actions[el.dataset.action]) {
      el.disabled = true;
      try {
        await actions[el.dataset.action](el);
      } finally {
        el.disabled = false;
      }
    }
  } catch (err) {
    fail(err);
  }
});
document.addEventListener("submit", async (e) => {
  if (!forms[e.target.id]) return;
  e.preventDefault();
  if (authBusy) return;
  const button = e.target.querySelector("button:not([type]),button[type=submit]");
  if (button) button.disabled = true;
  try {
    await forms[e.target.id](e.target);
  } catch (err) {
    fail(err);
  } finally {
    if (button) button.disabled = false;
  }
});
document.addEventListener("change", (e) => {
  if (e.target.id === "kind") {
    state.kind = e.target.value;
    navigate(state.page).catch(fail);
  }
  if (e.target.id === "damageMode") {
    const login = e.target.value === "login";
    $("#passwordRow").hidden = !login;
    $("#password").required = login;
  }
});
$("#modal").addEventListener("cancel", (e) => {
  e.preventDefault();
  close();
});
window.addEventListener("hashchange", () => {
  const page = location.hash.slice(1);
  if (!authBusy && labels[page] && page !== state.page) navigate(page).catch(fail);
});
(async () => {
  try {
    const options = await api("/api/nosternity/auth/options");
    if (options.origin !== location.origin) throw Error(messages.origin_rejected);
    await restore();
    await navigate(labels[location.hash.slice(1)] ? location.hash.slice(1) : "explore");
  } catch (e) {
    $("#content").innerHTML = blank("Dashboard setup needs attention", e.message);
    $("#mode").textContent = "\u25CB Service unavailable";
  }
})();
/*! Bundled license information:

@noble/hashes/utils.js:
  (*! noble-hashes - MIT License (c) 2022 Paul Miller (paulmillr.com) *)

@noble/curves/utils.js:
@noble/curves/abstract/modular.js:
@noble/curves/abstract/curve.js:
@noble/curves/abstract/weierstrass.js:
@noble/curves/secp256k1.js:
  (*! noble-curves - MIT License (c) 2022 Paul Miller (paulmillr.com) *)

@noble/ciphers/utils.js:
  (*! noble-ciphers - MIT License (c) 2023 Paul Miller (paulmillr.com) *)

@scure/base/index.js:
  (*! scure-base - MIT License (c) 2022 Paul Miller (paulmillr.com) *)
*/
