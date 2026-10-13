from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Tuple

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature, decode_dss_signature

Curve = ec.SECP256R1()


# ----------------------------
# Canonicalization (deterministic collisions)
# ----------------------------

_ws_re = re.compile(r"\s+")

def canonical_fact(s: str) -> str:
    """
    Minimal canonicalization:
    - strip
    - collapse whitespace runs
    Keep semantics safe: do NOT lowercase unless your spec says so.
    """
    s = s.strip()
    s = _ws_re.sub(" ", s)
    return s


def domain_separate(domain: str, canonical: str) -> bytes:
    """
    Subfield isolation: make 'AU|...' and 'UK|...' distinct inputs.
    """
    return (domain + "|" + canonical).encode("utf-8")


# ----------------------------
# Deterministic hash -> curve point (try-and-increment)
# ----------------------------

def sha256(b: bytes) -> bytes:
    d = hashes.Hash(hashes.SHA256())
    d.update(b)
    return d.finalize()

def _attempt_point_from_x32(x32: bytes, y_even: bool = True) -> ec.EllipticCurvePublicKey | None:
    """
    Attempt to interpret x32 as an x-coordinate and decompress to a point.
    For SEC1 compressed encoding:
      prefix 0x02 => even y
      prefix 0x03 => odd y
    If x32 is not a valid x on the curve, cryptography will reject it.
    """
    prefix = b"\x02" if y_even else b"\x03"
    compressed = prefix + x32
    try:
        return ec.EllipticCurvePublicKey.from_encoded_point(Curve, compressed)
    except ValueError:
        return None

def hash_to_curve_point(domain: str, fact: str, max_tries: int = 4096) -> Tuple[ec.EllipticCurvePublicKey, int]:
    """
    Deterministic mapping:
      seed = sha256(domain||canonical_fact)
      x_i = sha256(seed || i_be32)[:32]  (or other deterministic derivation)
      attempt decompress
    Returns (PublicKey(point), counter_i).
    """
    canon = canonical_fact(fact)
    seed = sha256(domain_separate(domain, canon))

    for i in range(max_tries):
        i_bytes = i.to_bytes(4, "big")
        x32 = sha256(seed + i_bytes)[:32]
        pk = _attempt_point_from_x32(x32, y_even=True)
        if pk is not None:
            return pk, i

    raise RuntimeError(f"Failed to find curve point in {max_tries} tries (unexpected but possible).")


# ----------------------------
# Proofs: bind data <-> point with ECDSA signatures
# ----------------------------

def encode_point_uncompressed(pub: ec.EllipticCurvePublicKey) -> bytes:
    return pub.public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint,
    )

def proof_message(domain: str, canonical: str, point_bytes: bytes) -> bytes:
    """
    What gets signed. If this verifies, you have a cryptographic binding that:
      - this signer attested to (domain, canonical_fact) mapped to this exact point encoding
    """
    # Simple framing to avoid ambiguity.
    return b"|".join([
        b"ECAI_PROOF_v1",
        domain.encode("utf-8"),
        canonical.encode("utf-8"),
        point_bytes,
    ])

@dataclass(frozen=True)
class KnowledgeEncoding:
    domain: str
    canonical: str
    point_uncompressed: bytes
    tries: int
    # ECDSA signature (DER)
    signature: bytes

def encode_knowledge_with_proof(
    data: str,
    domain: str,
    signer_private_key: ec.EllipticCurvePrivateKey,
) -> KnowledgeEncoding:
    """
    Deterministic encode + signature proof of binding.
    """
    canonical = canonical_fact(data)
    point_pub, tries = hash_to_curve_point(domain, canonical)
    pbytes = encode_point_uncompressed(point_pub)

    msg = proof_message(domain, canonical, pbytes)
    sig = signer_private_key.sign(msg, ec.ECDSA(hashes.SHA256()))

    return KnowledgeEncoding(
        domain=domain,
        canonical=canonical,
        point_uncompressed=pbytes,
        tries=tries,
        signature=sig,
    )

def verify_knowledge_proof(
    encoding: KnowledgeEncoding,
    signer_public_key: ec.EllipticCurvePublicKey,
) -> bool:
    """
    Verify:
      1) signature binds (domain, canonical, point_bytes)
      2) point_bytes is a valid curve point
    """
    # Ensure point bytes parse as a valid point on the curve
    try:
        _ = ec.EllipticCurvePublicKey.from_encoded_point(Curve, encoding.point_uncompressed)
    except ValueError:
        return False

    msg = proof_message(encoding.domain, encoding.canonical, encoding.point_uncompressed)
    try:
        signer_public_key.verify(encoding.signature, msg, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


# ----------------------------
# Demo: canonical collision, subfield isolation, zero-knowledge discovery behavior
# ----------------------------

def demo():
    # Authority key (the “proof anchor”)
    sk = ec.generate_private_key(Curve)
    pk = sk.public_key()

    # 1) Canonical collision test
    a = "Tax Rate: 10%"
    b = "  Tax   Rate:\n\t10%  "
    ea = encode_knowledge_with_proof(a, "AU", sk)
    eb = encode_knowledge_with_proof(b, "AU", sk)

    print("Canonical A:", ea.canonical)
    print("Canonical B:", eb.canonical)
    print("Same canonical?", ea.canonical == eb.canonical)
    print("Same point?", ea.point_uncompressed == eb.point_uncompressed)
    print("Proof verifies A?", verify_knowledge_proof(ea, pk))
    print("Proof verifies B?", verify_knowledge_proof(eb, pk))

    # 2) Subfield isolation test
    au = encode_knowledge_with_proof("Tax Rate: 10%", "AU", sk)
    uk = encode_knowledge_with_proof("Tax Rate: 10%", "UK", sk)
    print("AU point == UK point?", au.point_uncompressed == uk.point_uncompressed)

    # 3) Zero-knowledge discovery (strict retrieval) — toy index
    # Store: term -> point (you can store point -> payload too)
    index = {}
    index[("AU", "Tax Rate")] = au.point_uncompressed

    def get(term_domain: str, term: str) -> bytes | None:
        return index.get((term_domain, term), None)

    print("Lookup existing:", get("AU", "Tax Rate") is not None)
    print("Lookup missing:", get("AU", "Fictitious Rule") is None)
    print("Lookup cross-subfield:", get("UK", "Tax Rate") is None)

if __name__ == "__main__":
    demo()
