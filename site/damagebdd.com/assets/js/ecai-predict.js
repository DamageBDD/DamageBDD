// ECAI Token Prediction via Curve Mapping (secp256k1)
// Requires elliptic.js

const ec = new elliptic.ec('secp256k1');
const BN = elliptic.utils?.toBN || elliptic.ec('secp256k1').n.constructor;

const tokenMap = new Map();
const pointMap = new Map();

// Utility: hash string to scalar
async function sha256(text) {
  const encoded = new TextEncoder().encode(text);
  const hashBuffer = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function tokenToPoint(token) {
  if (pointMap.has(token)) return pointMap.get(token);

  const hash = await sha256(token);
  const scalar = BigInt("0x" + hash);
  const nBigInt = BigInt(ec.curve.n.toString(10)); // convert BN to BigInt safely

  const scalarMod = scalar % nBigInt;

      const bnScalar = new BN(scalarMod.toString());  // ✅ Safe for elliptic
  const point = ec.g.mul(bnScalar);

  pointMap.set(token, point);
  return point;
}

// Build dictionary of known tokens (can be expanded)
async function buildDictionary(tokens) {
  for (const t of tokens) {
    const point = await tokenToPoint(t);

    tokenMap.set(t, point);
  }
}

// Sum state vector of current feature tokens
async function getFeatureState(tokens) {
  const points = await Promise.all(tokens.map(tokenToPoint));
  return points.reduce((acc, pt) => acc.add(pt), ec.curve.point(null, null));
}

// Predict next token (argmin Euclidean distance)

async function predictNextToken(tokens) {
  const state = await getFeatureState(tokens);
  let minDist = Infinity;
  let prediction = null;
  for (const [token, point] of tokenMap.entries()) {
    const nextState = state.add(point);
    const dist = nextState.getX().toRed().fromRed().toString(10).length;
    if (dist < minDist) {
      minDist = dist;
      prediction = token;
    }
  }
  return prediction;
}

// Example usage:
// await buildDictionary(["Given", "I", "make", "a", "GET", "request"]);
// const next = await predictNextToken(["Given", "I"]);
// console.log("Next token:", next);
