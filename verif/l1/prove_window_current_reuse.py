"""All-bit abstract combinational proof backed by the extracted native miter.

This is a manually stated Boolean/bitvector contract, not automatic RTL formal
elaboration or a sequential cache/ISA proof. Independent hit/match/fill inputs
over-approximate the real leaf; no core-only exclusion assumption is used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

from test_window_current_reuse import sha


def formal():
    text='(set-logic QF_BV)\n'
    for n in ('chain prime_enabled pair_enabled windows two_windows code_buffer '
              'req we rd_match rd_armed next_req intent idle prime_extra early stream '
              'cache golden flush snoop code current_hit next_hit valid shadow_valid').split():
        text+=f'(declare-const {n} Bool)\n'
    for n,w in (('addr',32),('saved_addr',32),('shadow_addr',27)):
        text+=f'(declare-const {n} (_ BitVec {w}))\n'
    def term(name,body):
        nonlocal text
        text+=f'(define-fun {name} () Bool {body})\n'
    term('old_lookup','(and chain next_req req (not we) rd_match '
         '(not (and pair_enabled intent)) idle (not early) (not stream))')
    term('prime_lookup','(and chain prime_enabled next_req (not req) (not rd_armed) '
         '(not (and pair_enabled intent)) (or idle prime_extra) (not early) (not stream))')
    term('lookup','(or old_lookup prime_lookup)')
    term('selected_hit','(ite lookup next_hit current_hit)')
    term('common','(and req (not we) idle (not early) (not stream) cache '
         '(not golden) (not flush) (not snoop) (not (and code_buffer code)) '
         '(bvule ((_ extract 4 0) addr) #b11100))')
    term('primary_owner','(and windows valid (= ((_ extract 31 5) addr) ((_ extract 31 5) saved_addr)))')
    term('shadow_owner','(and windows two_windows shadow_valid (= ((_ extract 31 5) addr) shadow_addr))')
    term('cofactor','(not (and chain next_req rd_match (not (and pair_enabled intent))))')
    for label in ('primary','shadow'):
        term('old_'+label,f'(and {label}_owner common (not lookup) selected_hit)')
        term('new_'+label,f'(and {label}_owner common cofactor current_hit)')
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();leaf=args.leaf.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    start=json.loads((leaf/'started.json').read_text());closed=json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert closed['source_scope_exact'] and len(closed['rows'])==15
    assert sum(not r['expected_failure'] for r in closed['rows'])==9
    assert all(r['native_exit']==(1 if r['expected_failure'] else 0) for r in closed['rows'])
    assert all('WINDOW-REUSE-OK checks=344071 ' in r['coverage'] for r in closed['rows'] if not r['expected_failure'])
    pins=dict(start['pins'])
    for row in closed['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__).resolve(),leaf/'started.json',leaf/'closed.json',Path('/usr/bin/z3')):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    cases=[('primary-equivalence','(not (= old_primary new_primary))','unsat'),
           ('shadow-equivalence','(not (= old_shadow new_shadow))','unsat'),
           ('current-excludes-prime','(and common prime_lookup)','unsat'),
           ('reuse-selects-current','(and common (not lookup) (not (= selected_hit current_hit)))','unsat'),
           ('lost-next-owner','(and primary_owner common current_hit (not old_primary))','sat'),
           ('wrong-tags','(and primary_owner common cofactor next_hit (not old_primary))','sat'),
           ('lost-residency','(and primary_owner common cofactor (not current_hit))','sat'),
           ('lost-primary-owner','(and common cofactor current_hit (not primary_owner))','sat')]
    root.mkdir();rows=[]
    for name,assertion,expected in cases:
        query=root/(name+'.smt2')
        query.write_text(formal()+'(assert '+assertion+')\n(check-sat)\n')
        done=subprocess.run(['/usr/bin/z3',str(query)],capture_output=True,text=True,timeout=10)
        log=root/(name+'.log');log.write_text(done.stdout+done.stderr)
        assert done.returncode==0 and done.stdout.strip()==expected,(name,done.stdout,done.stderr)
        rows.append(dict(name=name,answer=expected,native_exit=done.returncode,
                         query_sha256=sha(query),log_sha256=sha(log)))
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,pins_unchanged=True,rows=rows,
        invocation=os.environ['INVOCATION_ID'],abstract_combinational_contract=True,
        automatic_rtl_formal=False,sequential_cache=False,whole_core=False,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    with (root/'closed.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__':main()
