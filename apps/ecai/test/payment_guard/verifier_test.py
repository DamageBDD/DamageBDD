#!/usr/bin/env python3
"""Independent Python reconstruction and malicious-evidence regression tests."""
import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
APP=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('verify_payment_guard',APP/'tools/verify_payment_guard.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

class VerifierTests(unittest.TestCase):
    def setUp(self): self.document=v.seal(v.run('redirected'))
    def test_known_reference(self):
        result=v.verify(self.document);self.assertEqual(result['guarded_debits'],0)
    def test_all_ten_python_fixtures(self):
        for s in v.SCENARIOS:
            with self.subTest(scenario=s):self.assertEqual(v.verify(v.seal(v.run(s)))['status'],'verified')
    def test_200_javascript_exports_reconstruct_independently(self):
        source=f"""import {{runScenario,evidence,SCENARIOS}} from {json.dumps((APP/'priv/static/js/payment-guard-model.js').as_uri())};
import {{webcrypto}} from 'node:crypto';
for (const s of SCENARIOS) for (const limit of [50000,479999,480000,500000,1000000]) for (const clock of [0,14,15,60]) console.log(JSON.stringify(await evidence(runScenario(s.id,{{limit_cents:limit,advance_minutes:clock}}),webcrypto.subtle)));"""
        result=subprocess.run(['node','--input-type=module','-e',source],capture_output=True,text=True,check=True,timeout=30)
        lines=result.stdout.splitlines();self.assertEqual(len(lines),200)
        for line in lines:self.assertEqual(v.verify(json.loads(line))['status'],'verified')
    def test_checksum_tamper(self):
        self.document['lanes']['guarded']['balance_cents']-=1
        with self.assertRaisesRegex(ValueError,'Checksum'):v.verify(self.document)
    def rejected_after_rehash(self,body):
        body.pop('sha256',None)
        with self.assertRaises(ValueError):v.verify(v.seal(body))
    def test_rehashed_ledger_forgery(self):
        self.document['lanes']['guarded']['balance_cents']-=480000;self.rejected_after_rehash(self.document)
    def test_rehashed_check_forgery(self):
        self.document['lanes']['guarded']['receipts'][0]['checks'][5]['pass']=True;self.rejected_after_rehash(self.document)
    def test_rehashed_fixture_forgery(self):
        self.document['fixture']['supplier']['beneficiary']='DEMO-UNAPPROVED-999';self.rejected_after_rehash(self.document)
    def test_rehashed_label_forgery(self):
        self.document['lanes']['guarded']['receipts'][0]['checks'][0]['label']='Government certified';self.rejected_after_rehash(self.document)
    def test_rehashed_scope_or_version(self):
        for key,value in [('scope','production-payment'),('engine','v999'),('schema','unknown')]:
            d=copy.deepcopy(self.document);d[key]=value;self.rejected_after_rehash(d)
    def test_extra_or_missing_fields(self):
        d=copy.deepcopy(self.document);d['signed']=True;self.rejected_after_rehash(d)
        d=copy.deepcopy(self.document);del d['acceptance'];self.rejected_after_rehash(d)
    def test_invalid_controls(self):
        for c in [{'limit_cents':True},{'limit_cents':1},{'advance_minutes':15.5},{'advance_minutes':1000},{'hidden':True}]:
            with self.assertRaises(ValueError):v.run('legitimate',c)
    def test_duplicate_json_keys_nonfinite_float_and_oversize(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'evidence.json'
            for data in ['{"a":1,"a":2}','{"a":NaN}','{"a":1.0}',' '*1000001]:
                p.write_text(data)
                with self.assertRaises(ValueError):v.load(p)
    def test_file_roundtrip_and_cli_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'evidence.json';p.write_text(json.dumps(self.document))
            result=subprocess.run(['python3',str(APP/'tools/verify_payment_guard.py'),str(p)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0);self.assertEqual(json.loads(result.stdout)['status'],'verified')
            p.write_text('{}');result=subprocess.run(['python3',str(APP/'tools/verify_payment_guard.py'),str(p)],capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0);self.assertIn('REJECTED',result.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
