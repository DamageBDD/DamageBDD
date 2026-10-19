#!/usr/bin/env python3
import copy,json,unittest
from fractions import Fraction as Q
from fixtures import curve,certificate,explore,two,path
from reference_checker import verify_certificate,verify_exploration,isomorphic_q,invariants

class Certificates(unittest.TestCase):
    def test_equal_j_not_iso(self):
        a,b=curve(0,-1,0),curve(0,4,0)
        self.assertEqual(invariants(a)['j'],invariants(b)['j'])
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_scaled(self):
        a,b=curve(0,-1,0),curve(0,-16,0)
        self.assertTrue(verify_certificate(a,b,certificate(a,b)))
    def test_translated(self):
        a,b=curve(0,-1,0),curve(-12,32,0)
        self.assertTrue(verify_certificate(a,b,certificate(a,b)))
    def test_same_j_positive_fourth_obstruction(self):
        a,b=curve(0,1,0),curve(0,2,0)
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_general_twist(self):
        a,b=curve(0,-2,1),curve(0,-8,8)
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_negative_general_twist(self):
        a,b=curve(0,-2,1),curve(0,-2,-1)
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_sixth(self):
        a,b=curve(0,0,1),curve(0,0,64)
        self.assertTrue(verify_certificate(a,b,certificate(a,b)))
    def test_sixth_obstruction(self):
        a,b=curve(0,0,1),curve(0,0,2)
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_negative_sixth(self):
        a,b=curve(0,0,1),curve(0,0,-1)
        self.assertFalse(verify_certificate(a,b,certificate(a,b)))
    def test_rational_scale(self):
        a,b=curve(0,-2,1),curve(0,Q(-1,8),Q(1,64))
        self.assertTrue(verify_certificate(a,b,certificate(a,b)))
    def test_wrong_flag(self):
        a,b=curve(0,-1,0),curve(0,4,0);cert=certificate(a,b);cert['relation']='isomorphic'
        with self.assertRaises(ValueError):verify_certificate(a,b,cert)
    def test_wrong_root_bracket(self):
        a,b=curve(0,1,0),curve(0,2,0);cert=certificate(a,b);cert['power_test']['numerator_floor']=999
        with self.assertRaises(ValueError):verify_certificate(a,b,cert)
    def test_bad_invariant(self):
        a,b=curve(0,-1,0),curve(0,-16,0);cert=certificate(a,b);cert['source_invariants']['j']=['4','1']
        with self.assertRaises(ValueError):verify_certificate(a,b,cert)
    def test_wrong_witness(self):
        a,b=curve(0,-1,0),curve(0,-16,0);cert=certificate(a,b);cert['witness']['x_num']=[['4','1'],['3','1']]
        with self.assertRaises(ValueError):verify_certificate(a,b,cert)
    def test_grid_scaled_and_translated(self):
        count=0
        for a in range(-3,4):
            for b in range(-3,4):
                if 4*a**3+27*b*b==0:continue
                for u in [Q(1,2),Q(2),Q(3,2)]:
                    for shift in [Q(0),Q(2)]:
                        s=curve(0,a,b)
                        t=curve(-3*shift,3*shift**2+a*u**4,-shift**3-a*u**4*shift+b*u**6)
                        self.assertTrue(verify_certificate(s,t,certificate(s,t)));count+=1
        self.assertEqual(count,276)

class Explorations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.report=explore()
    def fresh(self):return copy.deepcopy(self.report)
    def test_seven_models_four_classes(self):
        r=verify_exploration(self.fresh());self.assertEqual(r['models'],7);self.assertEqual(r['local_q_classes'],4);self.assertEqual(r['non_isomorphic_to_source_models'],3)
    def test_one_hop(self):self.assertEqual(verify_exploration(explore(depth=1))['models'],4)
    def test_source_only(self):self.assertEqual(verify_exploration(explore(depth=0))['models'],1)
    def test_partial_budget(self):
        r=explore(max_curves=2);self.assertEqual(r['stop_reason'],'model_budget');self.assertEqual(verify_exploration(r)['models'],2)
    def test_different_source(self):self.assertEqual(verify_exploration(explore(seed=curve(0,-2,0),depth=1))['models'],2)
    def test_no_kernel_in_bounds(self):self.assertEqual(verify_exploration(explore(seed=curve(0,0,1),numerator=0))['models'],1)
    def test_group_forgery(self):
        r=self.fresh();r['results'][1]['local_class']=1
        with self.assertRaises(ValueError):verify_exploration(r)
    def test_comparison_forgery(self):
        r=self.fresh();r['results'][1]['comparison_to_source']['relation']='isomorphic'
        with self.assertRaises(ValueError):verify_exploration(r)
    def test_digest_forgery(self):
        r=self.fresh();r['results'][1]['artifact_sha256']='0'*64
        with self.assertRaises(ValueError):verify_exploration(r)
    def test_summary_forgery(self):
        r=self.fresh();r['summary']['local_q_classes']=999
        with self.assertRaises(ValueError):verify_exploration(r)
    def test_path_tamper_with_rehashed_bytes(self):
        import hashlib
        r=self.fresh();row=r['results'][1];p=json.loads(row['path_json']);p['steps'][0]['map']['degree']=3
        row['path_json']=json.dumps(p);row['artifact_sha256']=hashlib.sha256(row['path_json'].encode()).hexdigest()
        with self.assertRaises(ValueError):verify_exploration(r)
    def test_scope_is_not_completeness_or_novelty(self):
        r=verify_exploration(self.fresh());self.assertFalse(r['novelty_checked']);self.assertFalse(r['search_completeness_checked']);self.assertFalse(r['erlang_etf_hashes_checked'])

if __name__=='__main__':unittest.main(verbosity=2)
