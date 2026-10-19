#!/usr/bin/env python3
"""Independent exploration certificate checker (Python standard library only).

Checks exact path algebra, Q-isomorphism decisions, rational-power certificates,
local grouping and summaries. Checks SHA-256 of each embedded path's UTF-8 bytes.
Does NOT check Erlang ETF identities, signatures, history, completeness or novelty.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import math
import re
import sys
from fractions import Fraction as Q
from pathlib import Path

spec = importlib.util.spec_from_file_location("ecai_path_reference", Path(__file__).parents[1]/"math_pathfinder/reference_checker.py")
pathcheck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pathcheck)


def integer(x, bits=8192):
    if isinstance(x, bool) or not isinstance(x, (str, int)) or not re.fullmatch(r"-?[0-9]+", str(x)):
        raise ValueError("exact decimal integer required")
    if len(str(x)) > 2500:
        raise ValueError("certificate integer size limit")
    n = int(x)
    if abs(n).bit_length() > bits:
        raise ValueError("certificate integer bit limit")
    return n


def rational(v):
    if not isinstance(v, list) or len(v) != 2:
        raise ValueError("rational string pair required")
    return Q(integer(v[0]), integer(v[1]))


def invariants(curve):
    a, b, c = pathcheck.curve(curve)
    c4 = 16*(a*a - 3*b)
    c6 = -64*a**3 + 288*a*b - 864*c
    delta = (c4**3 - c6**2)/1728
    return {"short_a": -c4/48, "short_b": -c6/864,
            "j": c4**3/delta, "discriminant": delta}


def floor_root(n, k):
    if n < 0:
        raise ValueError("nonnegative radicand required")
    if k == 2:
        return math.isqrt(n)
    if k == 4:
        return math.isqrt(math.isqrt(n))
    lo, hi = 0, 1 << ((n.bit_length()+k-1)//k)
    while hi-lo > 1:
        mid = (lo+hi)//2
        if mid**k <= n:
            lo = mid
        else:
            hi = mid
    return lo


def required_power(source, target):
    si, ti = invariants(source), invariants(target)
    if si['j'] != ti['j']:
        return None
    a, b, aa, bb = si['short_a'], si['short_b'], ti['short_a'], ti['short_b']
    if not a:
        return 6, bb/b, 'sixth_power_obstruction'
    if not b:
        return 4, aa/a, 'fourth_power_obstruction'
    return 2, (bb/b)/(aa/a), 'square_obstruction'


def isomorphic_q(source, target):
    required = required_power(source, target)
    if required is None:
        return False
    k, ratio, _ = required
    if ratio < 0:
        return False
    n, d = floor_root(ratio.numerator, k), floor_root(ratio.denominator, k)
    return n**k == ratio.numerator and d**k == ratio.denominator


def verify_certificate(source, target, cert):
    if not isinstance(cert, dict) or cert.get('scope') != 'q_isomorphism':
        raise ValueError('isomorphism certificate scope')
    for key, curve in [('source_invariants', source), ('target_invariants', target)]:
        calculated = invariants(curve)
        if {name:rational(cert[key][name]) for name in calculated} != calculated:
            raise ValueError('invariant mismatch')
    required = required_power(source, target)
    iso = isomorphic_q(source, target)
    if cert.get('relation') != ('isomorphic' if iso else 'non_isomorphic'):
        raise ValueError('incorrect Q-isomorphism decision')
    if required is None:
        if cert.get('reason') != 'different_j_invariants':
            raise ValueError('j obstruction reason')
        return False
    k, ratio, reason = required
    power = cert['power_test']
    if integer(power['exponent']) != k or rational(power['ratio']) != ratio or power['exact'] is not iso:
        raise ValueError('rational-power test mismatch')
    if ratio < 0:
        if power.get('obstruction') != 'negative_even_power':
            raise ValueError('negative even power evidence')
    else:
        n, d = integer(power['numerator_floor']), integer(power['denominator_floor'])
        if n < 0 or d < 0 or not (n**k <= ratio.numerator < (n+1)**k and d**k <= ratio.denominator < (d+1)**k):
            raise ValueError('invalid integer-root bracket')
        exact = n**k == ratio.numerator and d**k == ratio.denominator
        if exact is not iso:
            raise ValueError('incorrect root exactness')
    if iso:
        u = rational(power['root'])
        if not u or u**k != ratio or rational(cert['forward_scale']) != u:
            raise ValueError('invalid scaling root')
        m = cert['witness']
        if m['degree'] != 1 or pathcheck.curve(m['domain']) != pathcheck.curve(source) or pathcheck.curve(m['codomain']) != pathcheck.curve(target):
            raise ValueError('isomorphism witness endpoints')
        pathcheck.verify_map(m)
        sa, _, _ = pathcheck.curve(source)
        ta, _, _ = pathcheck.curve(target)
        shift = (u*u*sa-ta)/3
        if rational(cert['x_shift']) != shift:
            raise ValueError('shift mismatch')
    elif cert.get('reason') != reason:
        raise ValueError('twist obstruction reason')
    return iso


def verify_exploration(report):
    if not isinstance(report, dict) or report.get('kind') != 'mathematical_exploration' or report.get('schema') != 1:
        raise ValueError('exploration schema required')
    rows = report.get('results')
    if not isinstance(rows, list) or not 1 <= len(rows) <= 32:
        raise ValueError('exploration result count')
    source = report['source']
    pathcheck.curve(source)
    seen, models, reps, noniso, checked_maps = set(), set(), [], 0, 0
    for index, row in enumerate(rows):
        model_id = row['model_id']
        if model_id in seen:
            raise ValueError('duplicate model ID')
        seen.add(model_id)
        curve = row['curve']
        model = pathcheck.curve(curve)
        if model in models:
            raise ValueError('duplicate exact curve model')
        models.add(model)
        if type(row['depth']) is not int or not 0 <= row['depth'] <= 3:
            raise ValueError('invalid model depth')
        if index == 0 and (pathcheck.curve(curve) != pathcheck.curve(source) or row['depth'] != 0):
            raise ValueError('first result must be source model')
        raw = row['path_json']
        if not isinstance(raw, str) or len(raw.encode('utf-8')) > 262144:
            raise ValueError('path JSON limit')
        if hashlib.sha256(raw.encode('utf-8')).hexdigest().upper() != row['artifact_sha256'].upper():
            raise ValueError('path byte digest mismatch')
        path = json.loads(raw)
        if len(path['steps']) > 3:
            raise ValueError('exploration path depth limit')
        if any(step['map']['degree'] != 2 for step in path['steps']):
            raise ValueError('exploration requires degree-2 steps')
        result = pathcheck.verify_document(path)
        checked_maps += result['maps']
        if pathcheck.curve(path['source']) != pathcheck.curve(source) or pathcheck.curve(path['target']) != pathcheck.curve(curve):
            raise ValueError('exploration path endpoints')
        if path['hops'] != row['depth'] or path['id'] != row['path_id']:
            raise ValueError('path depth/label mismatch')
        if not verify_certificate(source, curve, row['comparison_to_source']):
            noniso += 1
        group = row['local_class']
        if type(group) is not int or not 1 <= group <= len(reps)+1:
            raise ValueError('invalid local class number')
        if group == len(reps)+1:
            if any(isomorphic_q(rep['curve'], curve) for rep in reps):
                raise ValueError('one Q-class split into multiple groups')
            reps.append(row)
        rep = reps[group-1]
        if row['representative_id'] != rep['model_id'] or not verify_certificate(rep['curve'], curve, row['class_certificate']):
            raise ValueError('incorrect class membership')
    expected = dict(retained_models=len(rows), reachable_other_models=len(rows)-1,
        non_isomorphic_to_source_models=noniso, isomorphic_to_source_other_models=len(rows)-noniso-1,
        local_q_classes=len(reps), non_source_q_classes=len(reps)-1)
    if not all(type(v) is int for v in report['summary'].values()) or report['summary'] != expected:
        raise ValueError('exploration summary mismatch')
    return dict(status='algebra_and_q_classification_verified',models=len(rows),
        local_q_classes=len(reps),non_isomorphic_to_source_models=noniso,
        path_map_occurrences_checked=checked_maps,path_byte_sha256_checked=True,
        erlang_etf_hashes_checked=False,search_completeness_checked=False,
        provenance_authenticated=False,novelty_checked=False,formal_proof=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file',type=Path)
    args=parser.parse_args()
    try:
        with args.file.open('rb') as f:
            raw=f.read(1_048_577)
        if len(raw)>1_048_576:
            raise ValueError('report size limit')
        print(json.dumps(verify_exploration(json.loads(raw)),indent=2))
        return 0
    except (ValueError,KeyError,TypeError,ZeroDivisionError,OSError,OverflowError) as exc:
        print(f'Exploration verification failed: {exc}',file=sys.stderr)
        return 1

if __name__=='__main__':
    raise SystemExit(main())
