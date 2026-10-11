#!/usr/bin/env python3
"""Prove producer selection under a conservative abstraction of the pinned guards.

This covers the choice of address-field source, not decoding, physical cache
behavior, state transitions, or timing. The extracted RTL test complements it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from prepare_mc_address_payload import transform


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args()
    core,out=a.core.resolve(strict=True),a.out.resolve()
    assert __debug__ and out.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    source=core/'core_mem_chain.svh'; transform(source.read_text())
    held=core/'core_raw_held_prime.svh'
    assert sha(held)=='032530542135f8744c332aa16fbfbf4bd36fac24230b8b1c20c4d989a0630040'
    # The actual equations imply these guards: held requires active; FP-self
    # requires !active and U.is_fp; paired-branch requires !active, !U.is_fp,
    # and paired issue. Everything else is left unconstrained (a superset).
    # Branch/FP/normal/held assignments have the exact descriptor priority.
    smt='''(set-logic QF_BV)
(declare-const active Bool) (declare-const valid Bool)
(declare-const pair Bool) (declare-const ufp Bool)
(declare-const held_rest Bool) (declare-const fp_rest Bool)
(declare-const branch_rest Bool) (declare-const v_checks Bool)
(declare-const held_pc Bool) (declare-const fp_checks Bool)
(declare-const branch_checks Bool) (declare-const branch_offset Bool)
(define-fun h () Bool (and active (not valid) held_rest))
(define-fun f () Bool (and (not active) (not valid) ufp fp_rest))
(define-fun b () Bool (and (not active) (not valid) (not ufp) pair branch_rest))
(define-fun v () Bool (and (not f) (not active) (not valid) (not pair) v_checks))
(define-fun old () (_ BitVec 3)
  (ite (and h held_pc) #b011
   (ite v #b001 (ite (and f fp_checks) #b010
    (ite (and b branch_offset branch_checks) #b100 #b000)))))
(define-fun new () (_ BitVec 3)
  (ite h #b011 (ite f #b010 (ite b (ite branch_offset #b100 #b000) #b001))))
'''
    cases=(('source-identity','(and (not (= old #b000)) (not (= old new)))','unsat'),
           ('always-v-mutant','(and (not (= old #b000)) (not (= old #b001)))','sat'),
           ('drop-held-mutant','(and h held_pc (not (= old (ite f #b010 #b001))))','sat'),
           ('unoffered-differences','(and (= old #b000) (not (= old new)))','sat'))
    pins={str(p):sha(p) for p in (source,held,Path(__file__),Path(__file__).with_name('prepare_mc_address_payload.py'),Path('/usr/bin/z3').resolve())}
    rows=[]
    for name, predicate, expected in cases:
        query=smt+'(assert '+predicate+')\n(check-sat)\n'
        p=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=query,text=True,capture_output=True,timeout=10)
        assert p.returncode==0 and p.stdout.strip()==expected,(name,p.returncode,p.stdout,p.stderr)
        rows.append(dict(name=name,native_exit=p.returncode,result=p.stdout.strip(),query=query))
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,pins_unchanged=True,checks=rows,
        scope='producer-source selection only; conservative guard abstraction',
        native_rtl=False,whole_core=False,timing_mhz=None,gameplay_ipc=None)
    with out.open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','checks')},indent=2))


if __name__=='__main__':main()
