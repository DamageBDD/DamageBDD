#!/usr/bin/env python3
"""Offline verification of exported signed manifest + MP4.

Usage:
  python scripts/verify_export.py manifest.json clip.mp4 TRUSTED_SIGNER_FINGERPRINT

The fingerprint MUST come from a trusted out-of-band channel (not the same
untrusted manifest), or the signature only proves internal consistency.
"""
import json
import sys
from pathlib import Path

from ecai_video_fastpath.crypto import digest_file, verify_seal

if len(sys.argv) != 4:
    raise SystemExit("Usage: verify_export.py manifest.json clip.mp4 TRUSTED_PUBLIC_KEY_FINGERPRINT_SHA256")
sealed = json.loads(Path(sys.argv[1]).read_text())
valid_signature = verify_seal(sealed, expected_fingerprint=sys.argv[3])
valid_video = digest_file(Path(sys.argv[2])) == sealed["manifest"]["video_sha256"]
print(json.dumps({"trusted_signature_valid": valid_signature, "mp4_sha256_matches": valid_video}))
sys.exit(0 if valid_signature and valid_video else 1)
