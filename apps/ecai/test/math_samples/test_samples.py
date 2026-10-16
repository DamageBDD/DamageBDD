"""Independent validation of the shipped candidates. Standard library only."""
import hashlib,json,sys,unittest
from copy import deepcopy
from fractions import Fraction as Q
from pathlib import Path
APP=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(APP/'test/math_pathfinder'))
from reference_checker import verify_document
ROOT=APP/'priv/static/math-samples'
CAT=json.loads((ROOT/'catalog.json').read_text())
class SampleTests(unittest.TestCase):
    def test_all_positive_candidates_independently(self):
        for item in CAT['samples']:
            if item['expected']!='accept':continue
            with self.subTest(sample=item['id']):self.assertEqual(verify_document(item['path']),item['reference_check'])
    def test_negative_control_is_rejected(self):
        item=next(s for s in CAT['samples'] if s['expected']=='reject')
        with self.assertRaisesRegex(ValueError,'nonzero cleared polynomial'):verify_document(item['path'])
    def test_exact_files_checksums_limits_and_no_fake_receipts(self):
        for item in CAT['samples']:
            with self.subTest(sample=item['id']):
                raw=(ROOT/item['file']).read_bytes();self.assertEqual(raw.decode(),item['path_json'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),item['path_sha256'])
                self.assertEqual(json.loads(raw),item['path']);self.assertLess(len(raw),192*1024)
                self.assertNotIn('verification',item['path']);self.assertLessEqual(item['path']['hops'],16)
    def test_tampering_every_positive_is_rejected(self):
        for item in CAT['samples']:
            if item['expected']!='accept':continue
            with self.subTest(sample=item['id']):
                p=deepcopy(item['path']);q=p['steps'][0]['map']['y_num'][0];n=Q(int(q[0]),int(q[1]))+1
                p['steps'][0]['map']['y_num'][0]=[str(n.numerator),str(n.denominator)]
                with self.assertRaises(ValueError):verify_document(p)
    def test_diverse_degrees_and_default(self):
        self.assertEqual(len(CAT['samples']),13);self.assertEqual(CAT['default_id'],'doubling-6')
        degrees={int(s['path']['total_degree']) for s in CAT['samples'] if s['expected']=='accept'}
        self.assertEqual(degrees,{1,2,3,4,5,6,8,9})
    def test_catalog_metadata_describes_candidates_not_live_jobs(self):
        for s in CAT['samples']:
            for bad in ['created_at_ms','checked_at_ms','payment','report_cid','job_id']:self.assertNotIn(bad,s)
            self.assertFalse(s['reference_check']['hashes_checked'])
if __name__=='__main__':unittest.main()
