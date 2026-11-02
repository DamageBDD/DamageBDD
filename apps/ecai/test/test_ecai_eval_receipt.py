#!/usr/bin/env python3
"""Standard-library tests for unsigned receipt byte integrity, not model grading."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[3]
SPEC=importlib.util.spec_from_file_location('receipt', ROOT/'tools/verify_ecai_eval_receipt.py')
receipt=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)

class ReceiptTests(unittest.TestCase):
    def sample(self):
        raw=json.dumps({'schema':'ecai-eval-evidence/v1','run':{'id':'test-run'},'note':'café'}, ensure_ascii=False)
        return {'manifest_bytes':raw,'sha256':hashlib.sha256(raw.encode()).hexdigest(),'signed':False}
    def test_exact_utf8_bytes(self):
        sample=self.sample(); out,raw=receipt.verify(sample)
        self.assertTrue(out['checksum_matches']);self.assertFalse(out['signature_verified'])
        self.assertEqual(sample['manifest_bytes'].encode(),raw)
        self.assertIsNone(out['externally_supplied_digest_matches'])
    def test_changed_manifest_is_rejected(self):
        sample=self.sample();sample['manifest_bytes']+=' '
        with self.assertRaises(ValueError):receipt.verify(sample)
    def test_wrong_external_digest_is_rejected(self):
        with self.assertRaises(ValueError):receipt.verify(self.sample(),'0'*64)
    def test_expected_digest(self):
        sample=self.sample();result,_=receipt.verify(sample,sample['sha256'])
        self.assertTrue(result['externally_supplied_digest_matches'])
        self.assertFalse(result['grading_recomputed'])
    def test_api_envelope(self):
        result,_=receipt.verify({'ok':True,'data':self.sample()})
        self.assertEqual('test-run',result['run_id'])
    def test_duplicate_keys(self):
        with self.assertRaises(ValueError):receipt.parse_json('{"signed":true,"signed":false}')
    def test_signature_claim_is_not_accepted(self):
        sample=self.sample();sample['signed']=True
        with self.assertRaises(ValueError):receipt.verify(sample)

if __name__=='__main__':unittest.main(verbosity=2)
