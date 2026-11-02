#!/usr/bin/env python3
# Test double for the privileged broker. Never executes script bytes.
import base64
import json
import sys
import time

req = json.loads(sys.stdin.buffer.readline())
script = base64.b64decode(req['script_b64'])
if script == b'wait':
    sys.stdin.buffer.read()  # EOF on manager cancellation/owner death
    sys.exit(0)
if script == b'crash':
    sys.exit(7)
if script == b'oversize':
    print('x' * 65536)
    sys.exit(0)
if script == b'invalid':
    print('not json')
    sys.exit(0)
print(json.dumps({'version': 1, 'ok': True, 'exit_code': 0,
                  'output_b64': req['script_b64'], 'output_truncated': False,
                  'vm_id': 'dmg-test', 'profile': req['profile'],
                  'kernel_sha256': 'a' * 64, 'rootfs_sha256': 'b' * 64,
                  'duration_ms': 1}))
