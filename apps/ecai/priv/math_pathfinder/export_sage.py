#!/usr/bin/env python3
"""Run with `sage -python export_sage.py ...`. No eval or network access.

Emit CANDIDATE rational isogenies for the native Erlang checker. A Sage result
or a database label is never imported as an already-verified relationship.
"""
from __future__ import annotations
import argparse
import json
import sys
from collections import deque
from fractions import Fraction
from pathlib import Path


def rational(text: str) -> Fraction:
    if len(text) > 310:
        raise ValueError("coefficient text is too long")
    q = Fraction(text)
    if max(abs(q.numerator).bit_length(), q.denominator.bit_length()) > 1024:
        raise ValueError("coefficient exceeds the native limit")
    return q


def q_wire(q) -> list[str]:
    return [str(q.numerator()), str(q.denominator())]


def curve_wire(curve) -> dict:
    a1, a2, a3, a4, a6 = curve.a_invariants()
    if a1 != 0 or a3 != 0:
        raise ValueError("native verifier requires a1=a3=0; convert the curve model first")
    return {"kind": "elliptic_curve", "field": "q",
            "a2": q_wire(a2), "a4": q_wire(a4), "a6": q_wire(a6)}


def map_wire(phi) -> dict:
    f = phi.x_rational_map()
    # For a1=a3=0: phi*omega_target = c*omega_source, so
    # Y = y * f'(x)/c. The native checker verifies this identity afresh.
    g = f.derivative() / phi.scaling_factor()
    return {"kind": "isogeny", "domain": curve_wire(phi.domain()),
            "codomain": curve_wire(phi.codomain()), "degree": int(phi.degree()),
            "x_num": [q_wire(c) for c in f.numerator().list()],
            "x_den": [q_wire(c) for c in f.denominator().list()],
            "y_num": [q_wire(c) for c in g.numerator().list()],
            "y_den": [q_wire(c) for c in g.denominator().list()]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--a2", default="0")
    parser.add_argument("--a4", default="-1")
    parser.add_argument("--a6", default="0")
    parser.add_argument("--depth", type=int, default=2)
    parser.add_argument("--degrees", type=int, nargs="+", default=[2, 3, 5])
    parser.add_argument("--max-curves", type=int, default=64)
    parser.add_argument("--max-edges", type=int, default=512)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        from sage.all import EllipticCurve, QQ, ZZ  # type: ignore[import-not-found]
        from sage.env import SAGE_VERSION  # type: ignore[import-not-found]
        if not 0 <= args.depth <= 4 or not 1 <= args.max_curves <= 256:
            raise ValueError("depth must be 0..4; max-curves must be 1..256")
        if not 1 <= args.max_edges <= 10000:
            raise ValueError("max-edges must be 1..10000")
        degrees = sorted(set(args.degrees))
        if not all(2 <= d <= 31 and ZZ(d).is_prime() for d in degrees):
            raise ValueError("degrees must be primes between 2 and 31")
        coeff = [rational(x) for x in (args.a2, args.a4, args.a6)]
        coeff = [QQ(q.numerator) / QQ(q.denominator) for q in coeff]
        seed = EllipticCurve(QQ, [0, coeff[0], 0, coeff[1], coeff[2]])
        queue = deque([(seed, 0)])
        seen = {tuple(seed.a_invariants()): seed}
        edges: dict[str, dict] = {}
        while queue:
            curve, depth = queue.popleft()
            if depth >= args.depth:
                continue
            candidates = [phi for d in degrees for phi in curve.isogenies_prime_degree(d)]
            records = sorted((map_wire(phi) for phi in candidates),
                             key=lambda r: json.dumps(r, sort_keys=True))
            for record in records:
                key = json.dumps(record, sort_keys=True, separators=(",", ":"))
                edges.setdefault(key, {"map": record, "cost": 1,
                                        "origins": [f"SageMath {SAGE_VERSION}; explicit prime-degree map"]})
                if len(edges) > args.max_edges:
                    raise ValueError("max-edges reached; reduce depth/degrees or raise the explicit limit")
                target = record["codomain"]
                aq = [QQ(int(target[k][0])) / QQ(int(target[k][1])) for k in ("a2", "a4", "a6")]
                target_curve = EllipticCurve(QQ, [0, aq[0], 0, aq[1], aq[2]])
                target_key = tuple(target_curve.a_invariants())
                if target_key not in seen:
                    if len(seen) >= args.max_curves:
                        raise ValueError("max-curves reached; no partial file has been written")
                    seen[target_key] = target_curve
                    queue.append((target_curve, depth + 1))
        result = {"schema": 1, "kind": "math_graph",
                  "curves": [curve_wire(seen[k]) for k in sorted(seen)],
                  "edges": [edges[k] for k in sorted(edges)]}
        data = json.dumps(result, sort_keys=True, indent=2) + "\n"
        if len(data.encode()) > 2_097_152:
            raise ValueError("output exceeds the native 2 MiB import limit")
        if args.output:
            with args.output.open("x", encoding="utf-8") as out:
                out.write(data)
        else:
            sys.stdout.write(data)
        print(f"Exported {len(seen)} exact curve models and {len(edges)} candidate maps.", file=sys.stderr)
        return 0
    except (ImportError, ValueError, TypeError, ArithmeticError, OSError) as exc:
        print(f"Sage export failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
