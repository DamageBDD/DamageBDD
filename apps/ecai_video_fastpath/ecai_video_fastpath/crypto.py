"""Canonical JSON, content commitments and secp256k1 provenance signatures.

A valid signature proves that the operator's key signed the manifest. To prove
operator identity, consumers MUST pin the trusted public-key fingerprint.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def canonical(obj: object) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


class Signer:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = directory / "signer-secp256k1.pem"
        if not path.exists():
            key = ec.generate_private_key(ec.SECP256K1())
            raw = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption())
            # Exclusive create: don't overwrite a key another process may have created.
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            try:
                with os.fdopen(fd, "wb") as fh:
                    fh.write(raw)
                    fh.flush()
                    os.fsync(fh.fileno())
            except Exception:
                try:
                    path.unlink()
                finally:
                    raise
        self.key = serialization.load_pem_private_key(path.read_bytes(), password=None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256K1):
            raise ValueError("Signer key must be secp256k1")
        self.pub = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                      serialization.PublicFormat.CompressedPoint)
        self.fingerprint = sha256(self.pub)

    def seal(self, manifest: dict) -> dict:
        payload = canonical(manifest)
        sig = self.key.sign(payload, ec.ECDSA(hashes.SHA256()))
        return {"manifest": manifest, "proof": {
            "algorithm": "ECDSA-secp256k1-SHA256",
            "public_key_hex": self.pub.hex(),
            "key_fingerprint_sha256": self.fingerprint,
            "manifest_sha256": sha256(payload),
            "signature_der_base64": base64.b64encode(sig).decode("ascii")}}


def verify_seal(sealed: dict, expected_fingerprint: str | None = None) -> bool:
    try:
        manifest, proof = sealed["manifest"], sealed["proof"]
        pub_bytes = bytes.fromhex(proof["public_key_hex"])
        if proof["algorithm"] != "ECDSA-secp256k1-SHA256":
            return False
        if proof["key_fingerprint_sha256"] != sha256(pub_bytes):
            return False
        if expected_fingerprint and proof["key_fingerprint_sha256"] != expected_fingerprint:
            return False
        payload = canonical(manifest)
        if sha256(payload) != proof["manifest_sha256"]:
            return False
        pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256K1(), pub_bytes)
        sig = base64.b64decode(proof["signature_der_base64"], validate=True)
        pub.verify(sig, payload, ec.ECDSA(hashes.SHA256()))
        return True
    except (ValueError, KeyError, TypeError, InvalidSignature, OverflowError, binascii.Error):
        return False
