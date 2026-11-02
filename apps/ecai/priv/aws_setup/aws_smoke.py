#!/usr/bin/env python3
"""Run INSIDE the approved worker image. Only synthetic setup data is processed."""
import hashlib
import json
import os
import re
import sys
import boto3
from botocore.config import Config

def main():
    bucket, prefix = os.environ['ECAI_PROBE_BUCKET'], os.environ['ECAI_PROBE_PREFIX']
    if not re.fullmatch(r'ecai-auto-\d{12}-[a-f0-9]{32}', bucket) or not re.fullmatch(r'staging/setup-probe/[a-f0-9]{32}/', prefix):
        raise ValueError('invalid probe location')
    s3 = boto3.client('s3', config=Config(connect_timeout=5, read_timeout=10, retries={'total_max_attempts':2}))
    response = s3.get_object(Bucket=bucket, Key=prefix+'input.json')
    try:
        body = response['Body'].read(4097)
    finally:
        response['Body'].close()
    if len(body) > 4096:
        raise ValueError('probe input too large')
    data = json.loads(body)
    if data.get('nonce') != prefix.split('/')[2] or data.get('schema') != 'ecai-aws-probe/v1':
        raise ValueError('unexpected input')
    out = json.dumps({'nonce':data['nonce'], 'input_sha256':hashlib.sha256(body).hexdigest()}).encode()
    s3.put_object(Bucket=bucket, Key=prefix+'output.json', Body=out, ContentType='application/json')
    print('ECAI synthetic storage probe completed')

if __name__ == '__main__':
    try: main()
    except Exception:
        # SDK exceptions can expose signed URLs or credentials. Do not log them.
        print('ECAI synthetic probe failed', file=sys.stderr)
        sys.exit(1)
