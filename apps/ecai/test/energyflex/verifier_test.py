#!/usr/bin/env python3
"""Cross-language and tamper tests. Run from any working directory."""
import copy
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('energyflex_verifier',HERE.parents[1]/'tools/verify_energyflex.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

class EvidenceTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory()
  subprocess.run(['node',str(HERE/'export_fixtures.mjs'),cls.tmp.name],check=True,stdout=subprocess.PIPE)
  cls.records={p.stem:json.loads(p.read_text()) for p in Path(cls.tmp.name).glob('*.json')}
 @classmethod
 def tearDownClass(cls):cls.tmp.cleanup()
 def sample(self):return copy.deepcopy(self.records['evening.evidence'])
 def resign(self,e):
  payload={k:x for k,x in e.items() if k!='integrity'}
  e['integrity']['sha256']=hashlib.sha256(v.canonical(payload).encode()).hexdigest()
  return e
 def test_all_five_browser_model_exports_replay(self):
  self.assertEqual(len(self.records),5)
  for e in self.records.values():self.assertEqual(v.verify(e)['status'],'passed')
 def test_reference_numbers(self):
  r=v.verify(self.sample());self.assertEqual(r['saving_cents'],700);self.assertEqual(r['candidate_assignments'],450);self.assertEqual(r['feasible_assignments'],189)
 def test_modified_checksum_rejected(self):
  e=self.sample();e['fixture']['capacity_kw']=16
  with self.assertRaisesRegex(ValueError,'checksum'):v.verify(e)
 def test_rehashed_stale_plan_rejected(self):
  e=self.sample();e['fixture']['capacity_kw']=16
  with self.assertRaises(ValueError):v.verify(self.resign(e))
 def test_rehashed_invented_savings_rejected(self):
  e=self.sample();e['result']['comparison']['saving_cents']=9999
  with self.assertRaisesRegex(ValueError,'Savings'):v.verify(self.resign(e))
 def test_rehashed_changed_metrics_rejected(self):
  e=self.sample();e['result']['strategies']['optimal']['verification']['metrics']['peak_kw']=1
  with self.assertRaisesRegex(ValueError,'metrics'):v.verify(self.resign(e))
 def test_rehashed_duplicate_rejected(self):
  e=self.sample();e['result']['strategies']['optimal']['plan']['EV-A']=[0,0]
  with self.assertRaises(ValueError):v.verify(self.resign(e))
 def test_infeasible_not_a_success(self):
  e=copy.deepcopy(self.records['impossible.evidence']);e['result']['strategies']['optimal']['verification']={'passed':True}
  with self.assertRaisesRegex(ValueError,'infeasible'):v.verify(self.resign(e))
 def test_fake_native_backend_claim_rejected(self):
  e=self.sample();e['execution']='damagebdd-backend'
  with self.assertRaisesRegex(ValueError,'execution'):v.verify(self.resign(e))
 def test_changed_constraint_flags_rejected(self):
  e=self.sample();e['result']['strategies']['optimal']['verification']['checks'][0]['passed']=False
  with self.assertRaisesRegex(ValueError,'constraint'):v.verify(self.resign(e))
 def test_json_duplicate_keys_rejected(self):
  with self.assertRaisesRegex(ValueError,'Duplicate'):json.loads('{"a":1,"a":2}',object_pairs_hook=v.no_duplicates)
 def test_unknown_algorithm_rejected(self):
  e=self.sample();e['schema']='energyflex-v999'
  with self.assertRaises(ValueError):v.verify(self.resign(e))

if __name__=='__main__':unittest.main(verbosity=2)
