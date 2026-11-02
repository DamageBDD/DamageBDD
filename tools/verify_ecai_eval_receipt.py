#!/usr/bin/env python3
"""Verify the EXACT UTF-8 manifest bytes in an unsigned ECAI evaluation receipt.

A matching self-contained digest detects accidental changes only. An attacker can
replace both the bytes and digest. --expected-sha256 must come from a separately
trusted channel; it is not a substitute for validating the evaluation itself.
No signature, model-identity, factual-correctness or profitability claim is made.
"""
from __future__ import annotations
import argparse
import hashlib
import hmac
import json
from pathlib import Path
import re
import sys
from typing import Any

MAX_BYTES = 20 * 1024 * 1024

def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'Duplicate JSON key: {key}')
        result[key] = value
    return result

def parse_json(text: str) -> Any:
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON number')))

def digest_string(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', value):
        raise ValueError('Expected a 64-character hexadecimal SHA-256 digest')
    return value.lower()

def verify(payload: Any, expected: str | None = None) -> tuple[dict[str, Any], bytes]:
    if not isinstance(payload, dict):
        raise ValueError('Receipt must be an object')
    if 'data' in payload:
        if payload.get('ok') is not True:
            raise ValueError('API response is not successful')
        payload = payload['data']
    if not isinstance(payload, dict) or payload.get('signed') is not False:
        raise ValueError('Only unsigned v1 receipts are supported; no signature verification is implemented')
    text = payload.get('manifest_bytes')
    if not isinstance(text, str):
        raise ValueError('manifest_bytes must be a JSON string')
    raw = text.encode('utf-8')
    if len(raw) > 16 * 1024 * 1024:
        raise ValueError('Manifest exceeds 16 MiB')
    actual = hashlib.sha256(raw).hexdigest()
    if not hmac.compare_digest(actual, digest_string(payload.get('sha256'))):
        raise ValueError('Manifest checksum does not match the receipt')
    if expected is not None and not hmac.compare_digest(actual, digest_string(expected)):
        raise ValueError('Manifest does not match the separately supplied expected digest')
    manifest = parse_json(text)
    if not isinstance(manifest, dict) or manifest.get('schema') != 'ecai-eval-evidence/v1':
        raise ValueError('Unsupported manifest schema')
    run = manifest.get('run', {})
    if not isinstance(run, dict):
        raise ValueError('Invalid run metadata')
    return {'checksum_matches': True, 'sha256': actual, 'run_id': run.get('id'),
            'externally_supplied_digest_matches': True if expected is not None else None,
            'signature_verified': False, 'grading_recomputed': False,
            'notice': 'Unsigned receipt. A self-contained checksum does not establish authenticity, model identity or correctness.'}, raw

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path)
    parser.add_argument('--expected-sha256', help='Digest received over a separately trusted channel')
    parser.add_argument('--extract-manifest', type=Path, help='Write verified bytes to a NEW file; never overwrite')
    args = parser.parse_args()
    try:
        with args.receipt.open('rb') as source:
            data = source.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('Receipt exceeds 20 MiB')
        result, raw = verify(parse_json(data.decode('utf-8')), args.expected_sha256)
        if args.extract_manifest:
            with args.extract_manifest.open('xb') as target:
                target.write(raw)
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, RecursionError) as error:
        print(f'Receipt verification failed: {error}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
