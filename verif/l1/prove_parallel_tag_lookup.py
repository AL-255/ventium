#!/usr/bin/env python3
"""Prove selected tag hits for all two-state array contents and addresses.

Source-pinned equation proof, not whole-module formal equivalence. Valid bits,
tags, addresses and the selector are unrestricted; no request-valid assumptions
are necessary. Array reads have no state or side effects.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from prepare_parallel_tag_lookup import transform


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, out = args.source.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    candidate = transform(source.read_text())
    pins = {str(p): sha(p) for p in (source, Path(__file__),
        Path(__file__).with_name('prepare_parallel_tag_lookup.py'),
        Path('/usr/bin/z3').resolve())}
    rows = []
    # OFFW=5; every legal positive TAGW/IDXW address split. No impractical
    # memory is materialized: the solver's arrays are symbolic.
    for idx in range(1, 27):
        tag = 27-idx
        smt = f'''(set-logic QF_ABV)
(declare-const c (_ BitVec 32)) (declare-const n (_ BitVec 32))
(declare-const use_next Bool)
(declare-const tags (Array (_ BitVec {idx+1}) (_ BitVec {tag})))
(declare-const valid (Array (_ BitVec {idx+1}) Bool))
(define-fun address () (_ BitVec 32) (ite use_next n c))
(define-fun row ((a (_ BitVec 32)) (w (_ BitVec 1))) (_ BitVec {idx+1})
  (concat ((_ extract {idx+4} 5) a) w))
(define-fun hit ((a (_ BitVec 32)) (w (_ BitVec 1))) Bool
  (and (select valid (row a w))
       (= (select tags (row a w)) ((_ extract 31 {idx+5}) a))))
'''
        cases = (
            ('equivalence', '''(or
 (not (= (hit address #b0) (ite use_next (hit n #b0) (hit c #b0))))
 (not (= (hit address #b1) (ite use_next (hit n #b1) (hit c #b1)))))''', 'unsat'),
            ('reversed-select', '(not (= (hit address #b0) (ite use_next (hit c #b0) (hit n #b0))))', 'sat'),
            ('wrong-way', '(not (= (hit address #b1) (ite use_next (hit n #b0) (hit c #b1))))', 'sat'),
        )
        for name, predicate, expected in cases:
            query = smt+'(assert '+predicate+')\n(check-sat)\n'
            p = subprocess.run(['/usr/bin/z3', '-in', '-smt2'], input=query,
                capture_output=True, text=True, timeout=10)
            assert p.returncode == 0 and p.stdout.strip() == expected, (idx, name, p.stdout, p.stderr)
            rows.append(dict(index_width=idx, name=name, native_exit=p.returncode,
                             result=p.stdout.strip(), query=query))
    stable = all(sha(p) == h for p, h in pins.items())
    assert stable
    receipt = dict(passed=True, pins=pins, pins_unchanged=stable, checks=rows,
        candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
        scope='two-state first-line tag-hit equations; not whole RTL formal equivalence',
        native_rtl=False, whole_core=False, timing_mhz=None, gameplay_ipc=None)
    with out.open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps(dict(passed=True, geometries=26, positive_unsat=26,
                         deliberate_defects_sat=52, candidate_sha256=receipt['candidate_sha256'])))


if __name__ == '__main__':
    main()
