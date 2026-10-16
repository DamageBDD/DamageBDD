#!/usr/bin/env python3
import copy
import json
import unittest
from fractions import Fraction as Q
from pathlib import Path
from reference_checker import verify_map, verify_document, curve


def qw(q):
    q = Q(q)
    return [str(q.numerator), str(q.denominator)]


def cw(a,b,c):
    return dict(kind="elliptic_curve",field="q",a2=qw(a),a4=qw(b),a6=qw(c))


def two(a,b,c,r):
    a,b,c,r = map(Q,(a,b,c,r))
    if r**3+a*r*r+b*r+c:
        raise ValueError("not a root")
    aa, bb = a+3*r, b+2*a*r+3*r*r
    return dict(kind="isogeny",domain=cw(a,b,c),codomain=cw(-2*aa,aa*aa-4*bb,0),degree=2,
                x_num=list(map(qw,[r*r+a*r+b,a+r,1])),x_den=list(map(qw,[-r,1])),
                y_num=list(map(qw,[r*r-bb,-2*r,1])),y_den=list(map(qw,[r*r,-2*r,1])))


def fixture():
    first = two(0,-1,0,0)
    second = two(0,4,0,0)
    return dict(schema=1,kind="math_graph",curves=[first["domain"],first["codomain"],second["codomain"]],
                edges=[dict(map=m,cost=1,origins=["explicit rational 2-isogeny fixture"]) for m in (first,second)])


class ExactReferenceTests(unittest.TestCase):
    def test_fixture(self):
        self.assertEqual(verify_document(fixture())["maps"],2)

    def test_rational_root_grid(self):
        count=0
        for a in range(-3,4):
            for b in range(-3,4):
                for r in (Q(-1),Q(0),Q(1),Q(1,2),Q(-2,3)):
                    c=-(r**3+a*r*r+b*r)
                    try:
                        curve(cw(a,b,c))
                    except ValueError:
                        continue
                    m=two(a,b,c,r)
                    self.assertEqual(verify_map(m)["degree"],2)
                    count+=1
        self.assertGreater(count,180)

    def test_wrong_degree(self):
        m=two(0,-1,0,0); m["degree"]=3
        with self.assertRaises(ValueError): verify_map(m)

    def test_wrong_target(self):
        m=two(0,-1,0,0); m["codomain"]=cw(0,5,0)
        with self.assertRaises(ValueError): verify_map(m)

    def test_wrong_map(self):
        m=two(0,-1,0,0); m["x_num"][0]=qw(0)
        with self.assertRaises(ValueError): verify_map(m)

    def test_removable_factors(self):
        m=two(0,-1,0,0)
        # Multiply both x numerator and denominator by x+1.
        m["x_num"]=list(map(qw,[-1,-1,1,1]))
        m["x_den"]=list(map(qw,[0,1,1]))
        self.assertEqual(verify_map(m)["degree"],2)

    def test_zero_denominator(self):
        m=two(0,-1,0,0); m["x_den"]=[]
        with self.assertRaises(ValueError): verify_map(m)

    def test_singular_source(self):
        m=two(0,-1,0,0); m["domain"]=cw(0,0,0)
        with self.assertRaises(ValueError): verify_map(m)

    def test_composed_receipt(self):
        g=fixture()
        p=dict(schema=1,kind="mathematical_path",source=g["curves"][0],target=g["curves"][-1],
               steps=g["edges"],total_cost=2,total_degree="4",hops=2)
        self.assertEqual(verify_document(p)["total_degree"],4)
        p["total_degree"]="999"
        with self.assertRaises(ValueError): verify_document(p)

    def test_disconnected_receipt(self):
        g=fixture()
        p=dict(schema=1,kind="mathematical_path",source=g["curves"][0],target=g["curves"][-1],
               steps=list(reversed(g["edges"])),total_cost=2,total_degree="4",hops=2)
        with self.assertRaises(ValueError): verify_document(p)

    def test_negative_y_automorphism(self):
        m=two(0,-1,0,0)
        m["y_num"]=[qw(-Q(int(n),int(d))) for n,d in m["y_num"]]
        self.assertEqual(verify_map(m)["degree"],2)

    def test_fractional_scaling_isomorphism(self):
        u=Q(2,3)
        m=dict(kind="isogeny",domain=cw(0,-1,0),codomain=cw(0,-u**4,0),degree=1,
               x_num=list(map(qw,[0,u*u])),x_den=[qw(1)],y_num=[qw(u**3)],y_den=[qw(1)])
        self.assertEqual(verify_map(m)["degree"],1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
