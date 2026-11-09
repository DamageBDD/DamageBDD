#!/usr/bin/env python3
import copy,hashlib,importlib.util,json,subprocess,tempfile,unittest
from pathlib import Path
APP=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('frverify',APP/'tools/verify_food_rescue.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
def signed(payload):return {'payload':payload,'sha256':hashlib.sha256(v.canonical(payload).encode()).hexdigest()}
def envelope(scenario='everyday'):return signed({'schema':v.VERSION,'scope':v.SCOPE,'result':v.run(scenario)})
class VerifierTests(unittest.TestCase):
 def test_known_fixture(self):
  e=envelope();self.assertEqual(v.verify(e)['rescued_kg'],400);self.assertEqual(v.verify(e)['baseline_kg'],360)
 def test_all_616_javascript_python_parity(self):
  url=(APP/'priv/static/js/food-rescue-model.js').as_uri()
  code=f'''import {{runScenario,makeEvidence,SCENARIOS}} from {json.dumps(url)};
const values=[];for(const {{id}} of SCENARIOS)for(let capacityKg=80;capacityKg<=180;capacityKg+=10)for(let delayMinutes=0;delayMinutes<=30;delayMinutes+=5){{const controls={{capacityKg,delayMinutes}};values.push({{id,controls,sha256:(await makeEvidence(runScenario(id,controls))).sha256}});}}console.log(JSON.stringify(values));'''
  rows=json.loads(subprocess.run(['node','--input-type=module','-e',code],check=True,capture_output=True,text=True).stdout)
  self.assertEqual(len(rows),616)
  for row in rows:
   with self.subTest(scenario=row['id'],controls=row['controls']):
    payload={'schema':v.VERSION,'scope':v.SCOPE,'result':v.run(row['id'],row['controls'])}
    self.assertEqual(signed(payload)['sha256'],row['sha256'])
 def test_checksum_change(self):
  e=envelope();e['payload']['result']['rescue']['metrics']['rescuedKg']=999
  with self.assertRaisesRegex(ValueError,'SHA-256'):v.verify(e)
 def test_rehashed_metrics_rejected(self):
  p=envelope()['payload'];p['result']['rescue']['metrics']['rescuedKg']=999
  with self.assertRaisesRegex(ValueError,'reconstruction'):v.verify(signed(p))
 def test_rehashed_ledger_rejected(self):
  p=envelope()['payload'];p['result']['rescue']['ledger'][0]['kg']=1
  with self.assertRaisesRegex(ValueError,'reconstruction'):v.verify(signed(p))
 def test_rehashed_warm_reading_and_recall_rejected(self):
  for scenario in ['cold-chain','late-recall']:
   p=envelope(scenario)['payload'];p['result']['world']['lots'][5]['readings']=[3,3,3];p['result']['world']['incidents']=[]
   with self.assertRaises(ValueError):v.verify(signed(p))
 def test_rehashed_gate_flag_and_assignments_rejected(self):
  for field in ['gate','plan']:
   p=envelope()['payload']
   if field=='gate':p['result']['rescue']['gate'][0]['passed']=False
   else:p['result']['rescue']['plan']['assignments'][0]['trip']='A1'
   with self.assertRaisesRegex(ValueError,'reconstruction'):v.verify(signed(p))
 def test_unknown_fields_version_and_scope(self):
  for key,value in [('schema','v999'),('scope','production-certified'),('extra',1)]:
   p=envelope()['payload'];p[key]=value
   with self.assertRaises(ValueError):v.verify(signed(p))
  e=envelope();e['extra']=True
  with self.assertRaises(ValueError):v.verify(e)
 def test_duplicate_keys_floats_nonfinite_and_oversize(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'e.json'
   for text in ['{"x":1,"x":2}','{"x":1.0}','{"x":NaN}','{"x":Infinity}',' '* (v.MAX_BYTES+1)]:
    p.write_text(text)
    with self.assertRaises(ValueError):v.load(p)
 def test_boolean_control_is_not_integer(self):
  p=envelope()['payload'];p['result']['world']['controls']['delayMinutes']=False
  with self.assertRaises(ValueError):v.verify(signed(p))
 def test_recalls_reconstruct_recipient_holds_not_destroyed_food(self):
  e=envelope('late-recall');v.verify(e);r=e['payload']['result']['rescue']
  self.assertEqual(r['metrics']['rescuedKg'],310);self.assertEqual(r['metrics']['recipientHoldKg'],90)
  self.assertEqual({x['location'] for x in r['records'] if x['state']=='recall-hold'},{'kitchen'})
 def test_cli_pass_and_fail_exit_codes(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'e.json';p.write_text(json.dumps(envelope()))
   self.assertEqual(subprocess.run(['python3',str(APP/'tools/verify_food_rescue.py'),str(p)],capture_output=True).returncode,0)
   p.write_text('{}');self.assertEqual(subprocess.run(['python3',str(APP/'tools/verify_food_rescue.py'),str(p)],capture_output=True).returncode,1)
if __name__=='__main__':unittest.main(verbosity=2)
