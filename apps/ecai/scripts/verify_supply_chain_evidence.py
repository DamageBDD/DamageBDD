#!/usr/bin/env python3
"""Check the exact manifest bytes in a Recovery Lab evidence export.

This verifies an unkeyed content checksum, NOT authenticity, feasibility,
optimality, or the truth of an external shipment or sensor observation.
"""
from __future__ import annotations
import argparse
import hashlib
import hmac
import json
import sys
from pathlib import Path

DOMAIN = 'ecai-supply-chain/evidence-v1'
MAX_BYTES = 8 * 1024 * 1024

def verify(payload: object) -> dict:
    if not isinstance(payload, dict):
        raise ValueError('Evidence must be a JSON object.')
    if payload.get('schema') != DOMAIN or payload.get('domain') != DOMAIN:
        raise ValueError('Unsupported evidence schema or hash domain.')
    text, digest = payload.get('manifest_json'), payload.get('digest')
    if not isinstance(text, str) or not isinstance(digest, str):
        raise ValueError('manifest_json and digest must be strings.')
    if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        raise ValueError('Digest must be 64 lowercase hexadecimal characters.')
    actual = hashlib.sha256(DOMAIN.encode() + b'\x00' + text.encode('utf-8')).hexdigest()
    if not hmac.compare_digest(actual, digest):
        raise ValueError('Content checksum mismatch: the manifest or digest changed.')
    manifest = json.loads(text)
    if not isinstance(manifest, dict):
        raise ValueError('The checksummed manifest must be a JSON object.')
    return manifest

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path, help='Exported evidence JSON file')
    args = parser.parse_args()
    try:
        with args.file.open('rb') as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('Evidence export exceeds the 8 MiB verifier limit.')
        manifest = verify(json.loads(data))
    except (OSError, UnicodeError, ValueError, RecursionError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        return 1
    print(f'PASS: exact manifest checksum; scenario revision {manifest.get("revision", "unknown")}')
    print('No signature verified. No physical-world truth or optimality claim is established.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
