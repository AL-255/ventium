#!/usr/bin/env python3
"""Abstract owner/consumer proof for a prospective paired-response ACK cut.

No RTL is changed. This is not extracted-RTL formal verification. The exact
source identity is checked, but the transition relation below is a hand-written
Boolean abstraction of its raw-prime, no-dual-prime/no-regmem profile. Native
source-extracted and whole-core tests remain mandatory before promotion.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

CORE = '8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def query(case):
    flags = ('active we owned spipe terminal reset fault new_ok memory store_kind '
             'bank_accept abort walk_pending chain prime read_bus write_bus '
             'fragment_hold valid fsm fp_block live_ok').split()
    text = '(set-logic QF_UF)\n'
    text += ''.join(f'(declare-const {name} Bool)\n' for name in flags)
    terms = {
        # The full source has additional independent admission predicates.
        # Abstract them with new_ok; only the disjoint load/store kinds matter.
        'newload': '(and spipe (not active) new_ok memory (not store_kind))',
        'newstore': '(and spipe (not active) new_ok store_kind)',
        'newmem': '(or newload newstore)',
        'load': '(ite active (and spipe (not we)) newload)',
        'store': '(ite active (and spipe we) newstore)',
        # S_PIPE bus driver gives a load priority over a store. Fault/fragment
        # shaping is retained on BOTH acknowledgements, never assumed clear.
        'buswe': '(ite spipe (and (not load) store) true)',
        'ack': '(and (ite buswe write_bus read_bus) (not fragment_hold))',
        'readack': '(and read_bus (not fragment_hold))',
        # Existing native core assertion establishes this admission contract:
        # fresh V acceptance implies admitted U load, !ACK and !abort.
        'accept': '(and bank_accept newload (not ack) (not abort))',
        'done': '(and active spipe (not abort) (not walk_pending) ack)',
        'capture': '(and (not active) newmem (not abort) (or walk_pending (not ack)))',
        'active_next': '(ite (or reset fault) false (ite done chain (ite capture true (ite terminal false active))))',
        'we_next': '(ite reset false (ite (and done chain) false (ite (and (not done) capture) newstore we)))',
        # Raw next-read prime warms the cache but does not create a U owner.
        # Both terminal states and start_fault clear U and V together.
        'owned_next': '(ite (or reset fault) false (ite accept true (ite (or done prime terminal) false owned)))',
        'invariant': '(=> owned (and active (not we)))',
        'invariant_next': '(=> owned_next (and active_next (not we_next)))',
        'base': '(and spipe fsm (not fp_block) (or active live_ok))',
        'oldcommit': '(and base (not (and (or load store) (not ack))))',
        'readcommit': '(and base (not store) (or (not load) readack))',
        'oldready': '(and valid (or (not owned) oldcommit))',
        'newready': '(and valid (or (not owned) readcommit))',
    }
    if case == 'store-owner-mutant':
        terms['accept'] = terms['accept'].replace('newload', 'newstore')
    elif case == 'lost-completion-clear-mutant':
        terms['owned_next'] = terms['owned_next'].replace('(or done prime terminal)', '(or prime terminal)')
    elif case == 'lost-fault-clear-mutant':
        terms['owned_next'] = terms['owned_next'].replace('(or reset fault)', 'reset')
    elif case == 'missing-read-ack-mutant':
        terms['readcommit'] = terms['readcommit'].replace('(or (not load) readack)', 'true')
    elif case == 'raw-fragment-ack-mutant':
        terms['readcommit'] = terms['readcommit'].replace('readack', 'read_bus')
    elif case == 'lost-orphan-drain-mutant':
        terms['newready'] = '(and valid owned readcommit)'
    for name, term in terms.items():
        text += f'(define-fun {name} () Bool {term})\n'
    text += '(assert (not (and spipe terminal)))\n'
    if case == 'owner-reset':
        text += '(assert reset)\n(assert (not invariant_next))\n'
    else:
        text += '(assert invariant)\n'
        if case in ('owner-induction', 'store-owner-mutant',
                    'lost-completion-clear-mutant', 'lost-fault-clear-mutant'):
            text += '(assert (not invariant_next))\n'
        else:
            text += '(assert (not (= oldready newready)))\n'
    return text + '(check-sat)\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    source = args.core.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert sha(source) == CORE
    solver = Path(shutil.which('z3')).resolve(strict=True)
    pins = {str(p): sha(p) for p in (source, Path(__file__).resolve(), solver)}
    root.mkdir()
    result = dict(passed=False, pins=pins, rows=[], abstract_proof=True,
                  source_extracted=False, rtl_modified=False, whole_core=False,
                  fmax_mhz=None, gameplay_ipc=None)
    started = time.monotonic()
    try:
        for case in ('owner-reset', 'owner-induction', 'read-consumer',
                     'store-owner-mutant', 'lost-completion-clear-mutant',
                     'lost-fault-clear-mutant', 'missing-read-ack-mutant',
                     'raw-fragment-ack-mutant', 'lost-orphan-drain-mutant'):
            problem = root/(case+'.smt2')
            log = root/(case+'.log')
            problem.write_text(query(case))
            native = subprocess.run([solver, problem], text=True, capture_output=True, timeout=10)
            log.write_text(native.stdout+native.stderr)
            expected = 'sat' if case.endswith('-mutant') else 'unsat'
            result['rows'].append(dict(case=case, native_exit=native.returncode,
                answer=native.stdout.strip(), expected=expected,
                artifacts={str(p): sha(p) for p in (problem, log)}))
            assert native.returncode == 0 and native.stdout.strip() == expected, result['rows'][-1]
        result['passed'] = True
    finally:
        result.update(seconds=time.monotonic()-started,
                      pins_unchanged=all(sha(p) == value for p, value in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'pins'}, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
