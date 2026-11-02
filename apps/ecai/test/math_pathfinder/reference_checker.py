#!/usr/bin/env python3
"""Independent exact-arithmetic verifier (Python standard library only).

Unlike the Erlang coefficient-identity checker, this proves the cleared
polynomial vanishes by evaluating at degree_bound+1 DISTINCT exact points.
This is a polynomial identity argument, not probabilistic point sampling.
Checks map/chain algebra; it does NOT check Erlang ETF hashes or signatures.
"""
from __future__ import annotations
import argparse
import json
import sys
from fractions import Fraction as Q
from pathlib import Path


def q(value) -> Q:
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError("expected [numerator, denominator]")
    for item in value:
        if isinstance(item, bool) or not isinstance(item, (str, int)) or len(str(item)) > 310:
            raise ValueError("invalid or oversized rational coefficient")
    n, d = map(int, value)
    if max(abs(n).bit_length(), abs(d).bit_length()) > 1024:
        raise ValueError("coefficient limit")
    return Q(n, d)


def trim(p):
    p = list(p)
    while p and p[-1] == 0:
        p.pop()
    return p


def poly(value):
    if not isinstance(value, list) or len(value) > 65:
        raise ValueError("polynomial limit")
    return trim([q(c) for c in value])


def evaluate(p, x):
    acc = Q(0)
    for c in reversed(p):
        acc = acc * x + c
    return acc


def divmod_poly(a, b):
    if not b:
        raise ValueError("zero polynomial denominator")
    a, out = trim(a), [Q(0)] * max(0, len(a) - len(b) + 1)
    while a and len(a) >= len(b):
        offset, c = len(a) - len(b), a[-1] / b[-1]
        out[offset] += c
        for i, v in enumerate(b):
            a[i + offset] -= c * v
        a = trim(a)
    return trim(out), a


def reduce_fraction(n, d):
    if not d:
        raise ValueError("zero polynomial denominator")
    if not n:
        return [], [Q(1)]
    a, b = n, d
    while b:
        _, remainder = divmod_poly(a, b)
        a, b = b, remainder
    n, nr = divmod_poly(n, a)
    d, dr = divmod_poly(d, a)
    if nr or dr:
        raise ValueError("internal reduction error")
    factor = d[-1]
    return [v / factor for v in n], [v / factor for v in d]


def curve(value):
    if not isinstance(value, dict):
        raise ValueError("expected curve object")
    if value.get("kind") != "elliptic_curve" or value.get("field") != "q":
        raise ValueError("unsupported curve")
    a, b, c = (q(value[k]) for k in ("a2", "a4", "a6"))
    if a*a*b*b - 4*b**3 - 4*a**3*c - 27*c*c + 18*a*b*c == 0:
        raise ValueError("singular curve")
    return a, b, c


def verify_map(m):
    if not isinstance(m, dict):
        raise ValueError("expected map object")
    if m.get("kind") != "isogeny":
        raise ValueError("unsupported map")
    degree = m["degree"]
    if type(degree) is not int or not 1 <= degree <= 32:
        raise ValueError("degree limit")
    a, b, c = curve(m["domain"])
    at, bt, ct = curve(m["codomain"])
    n, d = reduce_fraction(poly(m["x_num"]), poly(m["x_den"]))
    p, l = reduce_fraction(poly(m["y_num"]), poly(m["y_den"]))
    dn, dd, dp, dl = [len(v) - 1 for v in (n, d, p, l)]
    if dn - dd != 1 or not p or dp != dl:
        raise ValueError("origin/pole order condition failed")
    if max(dn, dd) != degree:
        raise ValueError("declared degree mismatch")
    bound = max(3 + 2*dp + 3*dd,
                max(3*dn, 2*dn+dd, dn+2*dd, 3*dd) + 2*dl)
    for x in range(bound + 1):
        nx, dx, px, lx = [evaluate(v, Q(x)) for v in (n, d, p, l)]
        source = x**3 + a*x*x + b*x + c
        residual = source * px**2 * dx**3 - (nx**3 + at*nx**2*dx + bt*nx*dx**2 + ct*dx**3)*lx**2
        if residual:
            raise ValueError(f"nonzero cleared polynomial at exact x={x}")
    return {"degree": degree, "polynomial_degree_bound": bound,
            "exact_evaluations": bound + 1}


def verify_document(doc):
    if not isinstance(doc, dict):
        raise ValueError("expected document object")
    if doc.get("schema") != 1:
        raise ValueError("schema mismatch")
    kind = doc.get("kind")
    if kind == "math_graph":
        steps = doc["edges"]
    elif kind == "mathematical_path":
        steps = doc["steps"]
    else:
        raise ValueError("unsupported document")
    if len(steps) > 10000:
        raise ValueError("too many maps")
    checks = [verify_map(s["map"]) for s in steps]
    result = {"status": "algebraically_verified", "maps": len(checks),
              "method": "exact polynomial identity via degree bound", "hashes_checked": False,
              "checks": checks}
    if kind == "mathematical_path":
        current, total_degree, total_cost = curve(doc["source"]), 1, 0
        for step in steps:
            if curve(step["map"]["domain"]) != current:
                raise ValueError("disconnected path")
            current = curve(step["map"]["codomain"])
            total_degree *= step["map"]["degree"]
            cost = step["cost"]
            if type(cost) is not int or not 1 <= cost <= 1_000_000:
                raise ValueError("invalid cost")
            total_cost += cost
        if (current != curve(doc["target"]) or total_degree != int(doc["total_degree"])
                or total_cost != doc["total_cost"] or len(steps) != doc["hops"]):
            raise ValueError("path total or endpoint mismatch")
        result["total_degree"] = total_degree
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        with args.file.open("rb") as source:
            data = source.read(2_097_153)
        if len(data) > 2_097_152:
            raise ValueError("document limit")
        print(json.dumps(verify_document(json.loads(data)), indent=2))
        return 0
    except (ValueError, ZeroDivisionError, KeyError, TypeError, OSError) as exc:
        print(f"Verification failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
