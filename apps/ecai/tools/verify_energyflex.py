#!/usr/bin/env python3
"""Independently replay an EnergyFlex v1 evidence file (Python stdlib only).

Checks bytes against the embedded checksum, then independently derives both
heuristics, all constraints, metrics, exhaustive optimum and search counts.
A matching checksum is NOT an authenticated signature or sensor provenance.
"""
from __future__ import annotations
import argparse
import hashlib
import itertools
import json
import sys
from pathlib import Path
from typing import Any

SCOPE = 'Synthetic discrete model. No live devices, ECAI-native retrieval, LLM call, or DamageBDD backend run. SHA-256 is a checksum, not a signature.'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def strict_int(value: Any, low: int, high: int) -> bool:
    return type(value) is int and low <= value <= high


def validate(f: dict) -> None:
    require(isinstance(f, dict), 'Fixture must be an object.')
    n = len(f.get('slot_labels', []))
    require(strict_int(n, 1, 8), 'Horizon is outside the bounded model.')
    require(f.get('slot_hours') == 1 and type(f.get('slot_hours')) is int and f.get('currency') == 'AUD', 'Only integer one-hour AUD slots are supported.')
    require(all(isinstance(x, str) and len(x) <= 16 for x in f['slot_labels']), 'Invalid labels.')
    require(strict_int(f.get('capacity_kw'), 1, 100), 'Invalid site limit.')
    for key, high in [('prices_cents_per_kwh', 500), ('base_load_kw', 50)]:
        require(isinstance(f.get(key), list) and len(f[key]) == n and all(strict_int(x, 0, high) for x in f[key]), f'Invalid {key}.')
    tasks = f.get('tasks')
    require(isinstance(tasks, list) and 1 <= len(tasks) <= 4, 'Invalid fleet.')
    ids = set()
    for t in tasks:
        require(isinstance(t, dict) and t.get('id') in {'EV-A', 'EV-B', 'EV-C', 'EV-D'} and t['id'] not in ids, 'Invalid vehicle ID.')
        ids.add(t['id'])
        require(strict_int(t.get('power_kw'), 1, 22), 'Invalid charger power.')
        require(strict_int(t.get('grid_energy_kwh'), 1, 176) and t['grid_energy_kwh'] % t['power_kw'] == 0, 'Energy is not representable in whole slots.')
        require(strict_int(t.get('release_slot'), 0, n - 1) and strict_int(t.get('deadline_slot_exclusive'), t['release_slot'] + 1, n), 'Invalid availability window.')


def assess(f: dict, plan: dict) -> tuple[dict, dict]:
    tasks = f['tasks']
    require(isinstance(plan, dict) and set(plan) == {t['id'] for t in tasks}, 'Vehicle identities do not match.')
    loads = list(f['base_load_kw'])
    checks = dict.fromkeys(['vehicles', 'slots', 'unique', 'windows', 'energy', 'capacity'], True)
    delivered = {}
    energy = cost = complete = 0
    for t in tasks:
        slots = plan[t['id']]
        require(isinstance(slots, list) and len(slots) <= len(loads), 'Invalid slot list.')
        require(all(strict_int(s, 0, len(loads) - 1) for s in slots), 'Invalid slot index.')
        # The producers never create malformed/duplicate schedules. Reject them
        # even when an attacker changes the recorded pass flag to false.
        require(len(set(slots)) == len(slots), 'Duplicate charging hour.')
        valid = [s for s in slots if t['release_slot'] <= s < t['deadline_slot_exclusive']]
        checks['windows'] &= len(valid) == len(slots)
        supplied = len(valid) * t['power_kw']
        delivered[t['id']] = supplied
        checks['energy'] &= supplied == t['grid_energy_kwh']
        complete += supplied == t['grid_energy_kwh']
        for s in slots:
            loads[s] += t['power_kw']
            cost += t['power_kw'] * f['prices_cents_per_kwh'][s]
            energy += t['power_kw']
    checks['capacity'] = all(load <= f['capacity_kw'] for load in loads)
    base = sum(a * b for a, b in zip(f['base_load_kw'], f['prices_cents_per_kwh']))
    metrics = dict(charging_energy_kwh=energy, charging_cost_cents=cost, base_cost_cents=base,
                   total_variable_energy_cost_cents=cost + base, peak_kw=max(loads), load_kw_by_slot=loads,
                   delivered_by_vehicle=delivered, complete_vehicles=complete,
                   required_energy_kwh=sum(t['grid_energy_kwh'] for t in tasks))
    return metrics, checks


def heuristics(f: dict) -> tuple[dict, dict]:
    tasks = sorted(f['tasks'], key=lambda t: (t['deadline_slot_exclusive'], t['id']))
    early = {t['id']: [] for t in tasks}
    for s, base in enumerate(f['base_load_kw']):
        load = base
        for t in tasks:
            if (t['release_slot'] <= s < t['deadline_slot_exclusive'] and len(early[t['id']]) * t['power_kw'] < t['grid_energy_kwh'] and load + t['power_kw'] <= f['capacity_kw']):
                early[t['id']].append(s)
                load += t['power_kw']
    greedy = {t['id']: [] for t in tasks}
    loads = list(f['base_load_kw'])
    for t in tasks:
        available = sorted(range(t['release_slot'], t['deadline_slot_exclusive']), key=lambda s: (f['prices_cents_per_kwh'][s], s))
        for s in available:
            if len(greedy[t['id']]) * t['power_kw'] < t['grid_energy_kwh'] and loads[s] + t['power_kw'] <= f['capacity_kw']:
                greedy[t['id']].append(s)
                loads[s] += t['power_kw']
        greedy[t['id']].sort()
    return early, greedy


def exhaustive(f: dict) -> tuple[dict | None, dict]:
    options = [list(itertools.combinations(range(t['release_slot'], t['deadline_slot_exclusive']), t['grid_energy_kwh'] // t['power_kw'])) for t in f['tasks']]
    size = 1
    for option in options:
        size *= len(option)
    require(size <= 200000, 'Search exceeds the public model budget.')
    best = None
    best_cost = None
    evaluated = feasible = 0
    for choices in itertools.product(*options):
        evaluated += 1
        plan = {t['id']: list(s) for t, s in zip(f['tasks'], choices)}
        metrics, checks = assess(f, plan)
        if not all(checks.values()):
            continue
        feasible += 1
        cost = metrics['charging_cost_cents']
        if best_cost is None or cost < best_cost:
            best_cost = cost
            best = plan
    return best, dict(candidate_assignments=evaluated, feasible_assignments=feasible, complete=True)


def verify(evidence: dict) -> dict:
    require(isinstance(evidence, dict), 'Evidence must be an object.')
    require(set(evidence) == {'schema', 'execution', 'fixture', 'result', 'scope', 'integrity'}, 'Unknown or missing evidence fields.')
    require(evidence['schema'] == 'energyflex-v1' and evidence['execution'] == 'browser-local-reference' and evidence['scope'] == SCOPE, 'Unknown schema or execution claims.')
    integrity = evidence['integrity']
    require(isinstance(integrity, dict) and integrity.get('algorithm') == 'SHA-256' and integrity.get('canonicalization') == 'sorted-keys-compact-json-v1', 'Unknown checksum format.')
    payload = {k: v for k, v in evidence.items() if k != 'integrity'}
    digest = hashlib.sha256(canonical(payload).encode()).hexdigest()
    require(integrity.get('sha256') == digest, 'SHA-256 checksum mismatch.')
    f, result = evidence['fixture'], evidence['result']
    validate(f)
    early, tariff = heuristics(f)
    optimal, search = exhaustive(f)
    require(canonical(result.get('search')) == canonical(search), 'Search statistics do not replay.')
    expected = dict(earliest=early, tariff=tariff, optimal=optimal)
    require(set(result.get('strategies', {})) == set(expected), 'Unexpected strategy set.')
    assessed = {}
    for name, plan in expected.items():
        claimed = result['strategies'][name]
        require(canonical(claimed.get('plan')) == canonical(plan), f'{name}: declared strategy does not replay.')
        v = claimed.get('verification')
        if plan is None:
            require(v is None, 'An infeasible problem cannot have a successful verification.')
            assessed[name] = None
            continue
        metrics, checks = assess(f, plan)
        passed = all(checks.values())
        require(isinstance(v, dict) and canonical(v.get('metrics')) == canonical(metrics), f'{name}: metrics differ from the raw schedule.')
        require(v.get('passed') is passed, f'{name}: incorrect overall check result.')
        require(isinstance(v.get('checks'), list) and len(v['checks']) == len(checks), f'{name}: missing constraint checks.')
        actual_checks = {c.get('id'): c.get('passed') for c in v['checks']}
        require(actual_checks == checks and all(type(c.get('passed')) is bool for c in v['checks']), f'{name}: incorrect per-constraint results.')
        require(isinstance(v.get('failures'), list) and bool(v['failures']) is (not passed), f'{name}: failures inconsistent with constraints.')
        # Check structured failure rules; prose is explanatory, not authoritative.
        require({x.get('rule') for x in v['failures']} == {key for key, ok in checks.items() if not ok}, f'{name}: failure rules disagree with schedule.')
        assessed[name] = dict(metrics=metrics, passed=passed)
    first, opt = assessed['earliest'], assessed['optimal']
    comparable = bool(first and first['passed'] and opt and opt['passed'])
    saving = first['metrics']['total_variable_energy_cost_cents'] - opt['metrics']['total_variable_energy_cost_cents'] if comparable else None
    total = first['metrics']['total_variable_energy_cost_cents'] if comparable else 0
    # Exact equivalent of JS Math.round for the nonnegative ratios in this model.
    basis = (20000 * saving + total) // (2 * total) if comparable and total > 0 else None
    greedy = assessed['tariff']
    match = bool(opt and opt['passed'] and greedy['passed'] and greedy['metrics']['total_variable_energy_cost_cents'] == opt['metrics']['total_variable_energy_cost_cents'])
    comparison = dict(comparable=comparable, saving_cents=saving, saving_basis_points=basis, tariff_matches_optimum=match)
    require(canonical(result.get('comparison')) == canonical(comparison), 'Savings or baseline comparison does not replay.')
    return dict(status='passed', fixture=f['id'], checksum=digest, independent_python_replay=True, **search, **comparison)


def no_duplicates(pairs: list[tuple[str, Any]]) -> dict:
    out = {}
    for key, value in pairs:
        require(key not in out, f'Duplicate JSON key: {key}')
        out[key] = value
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    try:
        require(args.evidence.stat().st_size <= 512000, 'Evidence exceeds 512 kB.')
        data = json.loads(args.evidence.read_text(encoding='utf-8'), object_pairs_hook=no_duplicates,
                          parse_constant=lambda s: (_ for _ in ()).throw(ValueError(f'Invalid JSON number: {s}')))
        print(json.dumps(verify(data), indent=2))
        print('Scope: replayed synthetic model only; no trusted signer or physical sensor attestation.')
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError) as exc:
        print(f'REJECTED: {exc}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
