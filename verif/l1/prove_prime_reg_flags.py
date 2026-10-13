"""Universal selector/cofactor proof; ALU and condition helpers are uninterpreted.

This proves the complete commit equation for arbitrary shared helper functions,
not a replacement for full-core or ISA verification. Source hashes/guards and
the old/new operand selectors are explicitly bound to the frozen recipe.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import prepare_prime_reg_flags as recipe
from run_parallel_tag_cache import sha


def conjunction(expression):
    terms=[]
    for term in expression.strip().split('&&'):
        term=term.strip()
        assert re.fullmatch(r'!?\w+(?:\.\w+)?',term),term
        neg=term.startswith('!')
        name=term.lstrip('!').replace('.','_')
        terms.append('(not '+name+')' if neg else name)
    return '(and '+' '.join(terms)+')'


def problem(sources,profile):
    recipe.transform(sources)  # Bind the exact selectors, modules and helpers.
    header=sources['core_mem_chain.svh']
    groups={}
    for lane in ('u','v'):
        rows=re.findall(r'^  assign mc_prime_'+lane+r'_branch = (.*?);\n',header,re.M|re.S)
        assert len(rows)==3 and rows[2]=="1'b0"
        groups[lane]=['false',conjunction(rows[0]),conjunction(rows[1])]
    conditions=[groups[lane][profile] for lane in ('u','v')]
    words=set(re.findall(r'\b\w+\b',' '.join(conditions)))-{'and','not','false'}
    words |= set(('pipe_u_eff_is_mem pipe_u_eff_is_load pipe_u_eff_is_store pipe_u_eff_mem_lhs '
        'pipe_u_eff_wflags pipe_u_eff_is_shift pipe_u_eff_br_taken pipe_v_eff_br_cond '
        'u_pred_taken v_pred_taken mc_offer mc_prime_offer mc_readonly_int_commit '
        'mc_fp_self_prime fp_shared_mem_admit').split())
    text='(set-logic QF_UFBV)\n'
    text+=''.join('(declare-fun '+name+' () Bool)\n' for name in sorted(words))
    for name,width in (('dst',32),('src',32),('mem',32),('eflags',32),('shift',32),('decode',512),('cc',4)):
        text+=f'(declare-fun {name} () (_ BitVec {width}))\n'
    text+='''(declare-fun flags ((_ BitVec 512) (_ BitVec 32) (_ BitVec 32) (_ BitVec 32)) (_ BitVec 32))
(declare-fun cond ((_ BitVec 4) (_ BitVec 32)) Bool)
(define-fun old_dst () (_ BitVec 32) (ite (and pipe_u_eff_is_mem (not pipe_u_eff_is_load) (not pipe_u_eff_is_store) pipe_u_eff_mem_lhs) mem dst))
(define-fun old_src () (_ BitVec 32) (ite (and pipe_u_eff_is_mem (not pipe_u_eff_is_load) (not pipe_u_eff_is_store) (not pipe_u_eff_mem_lhs)) mem src))
(define-fun old_flags () (_ BitVec 32) (ite pipe_u_eff_is_shift shift (ite pipe_u_eff_wflags (flags decode old_dst old_src eflags) eflags)))
(define-fun new_flags () (_ BitVec 32) (ite pipe_u_eff_is_shift shift (ite pipe_u_eff_wflags (flags decode dst src eflags) eflags)))
(define-fun old_branch () Bool (ite pipe_v_eff_br_cond (cond cc old_flags) true))
(define-fun new_branch () Bool (ite pipe_v_eff_br_cond (cond cc new_flags) true))
'''
    text+='(define-fun prime_u () Bool '+conditions[0]+')\n'
    text+='(define-fun prime_v () Bool '+conditions[1]+')\n'
    for name,branch in (('old_commit','(= old_branch v_pred_taken)'),('new_commit','(= new_branch v_pred_taken)'),
                        ('wrong_prediction','(not (= new_branch v_pred_taken))')):
        text+='(define-fun '+name+' () Bool (and (or mc_offer (and mc_prime_offer '+\
              '(or (not (or prime_u prime_v)) (ite prime_u (= pipe_u_eff_br_taken u_pred_taken) '+branch+')))) '+\
              '(or mc_readonly_int_commit (and mc_fp_self_prime fp_shared_mem_admit))))\n'
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('source','out'):
        ap.add_argument('--'+key,required=True,type=Path)
    args=ap.parse_args()
    root=args.out.resolve();source=args.source.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    sources={name:(source/name).read_text() for name in recipe.PARENTS}
    pins={str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),Path('/usr/bin/z3'),*[source/n for n in recipe.PARENTS])}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream:json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),affinity=sorted(os.sched_getaffinity(0))))
    rows=[]
    for profile in (0,1,2):
        queries=[('commit-equality','(not (= old_commit new_commit))','unsat'),
                 ('guarded-outcome','(and prime_v (not (= old_branch new_branch)))','unsat')]
        if profile:
            queries += [('actual-offer','(and mc_prime_offer prime_v mc_readonly_int_commit)','sat'),
                        ('wrong-prediction-mutant','(not (= old_commit wrong_prediction))','sat')]
        for label,query,expected in queries:
            name=f'b{profile}-'+label
            text=problem(sources,profile)+'(assert '+query+')\n(check-sat)\n'
            (root/(name+'.smt2')).write_text(text)
            result=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=text,text=True,capture_output=True,timeout=15)
            (root/(name+'.stdout')).write_text(result.stdout)
            assert result.returncode==0 and not result.stderr and result.stdout.strip()==expected,(name,result)
            rows.append(dict(name=name,expected=expected,result=result.stdout.strip(),native_exit=0))
    assert all(sha(p)==h for p,h in pins.items())
    save('closed.json',dict(passed=True,pins_unchanged=True,rows=rows,whole_core_proof=False,
         uninterpreted_shared_helpers=True,hardware_acceptance=False,gameplay_ipc=None,
         artifacts={str(p):sha(p) for p in root.iterdir() if p.is_file()}))
    print('PRIME-REG-SMT-OK ten queries; all three commit profiles equivalent',flush=True)


if __name__=='__main__':main()
