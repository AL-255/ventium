"""All-bit combinational contract proof, backed by the native source miter.

This over-approximates registered cache state and independent early/code/bypass
ACK terms; it does not prove cache-state reachability or whole-core ISA behavior.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

from test_fp_high_valid_cofactor import sha


def formal():
    text='(set-logic QF_BV)\n'
    flags=('rst we cache golden flush snoop stream early idle byp rd_armed rd_code code '
           'window_valid shadow_valid full next_req prime_extra current_hit prime_hit '
           'early_match byp_match code_reuse stream_ack chain prime windows shadow code_buffer comb '
           'seam_rst core_req smram_deny route_deny dma_stall dl1c dl1c_last cd '
           'cycle fload qread qwrite fsm hold fxeng fxstart debug tf rf retire op').split()
    for name in flags:
        text+=f'(declare-const {name} Bool)\n'
    for name,width in (('addr',32),('rd_addr',32),('shadow_line',27),('strb',4),
                       ('bytes',4),('step',4),('lin_offset',12)):
        text+=f'(declare-const {name} (_ BitVec {width}))\n'
    def term(name,body,kind='Bool'):
        nonlocal text
        text+=f'(define-fun {name} () {kind} {body})\n'
    term('req','(and seam_rst core_req (not smram_deny) (not route_deny) (not dma_stall))')
    term('rd','(and rd_armed (not stream) (= addr rd_addr) (or (not code_buffer) (= rd_code code)))')
    term('lookup','(and chain next_req (not early) (not stream) '
         '(or (and req (not we) rd idle) '
         '(and prime (not req) (not rd_armed) (or idle prime_extra))))')
    term('hit','(ite lookup prime_hit current_hit)')
    term('no_code','(not (and code_buffer code))')
    term('same_primary','(= ((_ extract 31 5) addr) ((_ extract 31 5) rd_addr))')
    term('same_shadow','(= ((_ extract 31 5) addr) shadow_line)')
    term('extent28','(bvule ((_ extract 4 0) addr) #b11100)')
    term('extent24','(bvule ((_ extract 4 0) addr) #b11000)')
    term('reuse_common','(and (not lookup) (not stream) (not early) idle req (not we) cache '
         '(not golden) (not flush) (not snoop) hit no_code extent28)')
    term('window','(and windows window_valid same_primary reuse_common)')
    term('saved','(and windows shadow shadow_valid same_shadow reuse_common)')
    term('ack','(ite stream stream_ack (and req (not we) '
         '(or window saved code_reuse (and early_match (not flush) (not snoop)) '
         '(and rd (not flush) (not snoop) cache) (and byp byp_match))))')
    term('common','(and rst req (not we) (= strb #xf) cache (not golden) '
         '(not flush) (not snoop) (not stream) (not early) idle (not comb))')
    term('old_hi','(and common ack hit extent24 (not lookup) '
         '(or (and full same_primary (or rd window)) saved))')
    term('new_owner','(or (and full same_primary (or rd (and windows window_valid no_code))) '
         '(and windows shadow shadow_valid same_shadow no_code))')
    term('new_hi','(and common current_hit new_owner extent24 (not (and chain next_req rd)))')
    term('core_ack','(and seam_rst (not dma_stall) '
         '(or (and core_req (or smram_deny route_deny)) ack))')
    term('old_seam','(and req ack dl1c dl1c_last (not cd) old_hi)')
    term('new_seam','(and req dl1c dl1c_last (not cd) new_hi)')
    term('mem_ack','(and core_ack (not hold))')
    term('take_common','(and cycle fload qread (not qwrite) (= bytes #x8) (= step #x0) '
         'fsm (not fxeng) (not fxstart) (bvule lin_offset #xff8) (not debug) (not tf) (not rf))')
    term('old_take','(and take_common mem_ack old_seam)')
    term('new_take','(and take_common (not hold) new_seam)')
    term('cmd_common','(and cycle fload qread (not qwrite) fsm retire (not debug) op)')
    term('narrow','(and (= bytes #x4) (= step #x0))')
    term('second','(and (= bytes #x8) (= step #x1))')
    term('old_cmd','(and cmd_common mem_ack (or narrow (and (= bytes #x8) (or (= step #x1) old_take))))')
    term('new_cmd','(and cmd_common (or (and mem_ack (or narrow second)) new_take))')
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.out.resolve(); leaf=args.leaf.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    prior=json.loads((leaf/'closed.json').read_text())
    assert prior['passed'] and prior['pins_unchanged']
    assert [(r['label'],r['native_exit']) for r in prior['rows']]==[
        ('positive',0),('lost-next-owner',1),('lost-residency',1),('lost-full-line',1),
        ('wrong-extent',1),('narrow-without-ack',1)]
    pins=dict(prior['pins'])
    for row in prior['rows']: pins.update(row['artifacts'])
    for p in (Path(__file__).resolve(),leaf/'closed.json'): pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    cases=[('l1-equivalence','(not (= old_hi new_hi))','unsat'),
           ('l1-ack-implication','(and new_hi (not ack))','unsat'),
           ('seam-equivalence','(not (= old_seam new_seam))','unsat'),
           ('seam-ack-implication','(and new_seam (not core_ack))','unsat'),
           ('take-equivalence','(not (= old_take new_take))','unsat'),
           ('command-equivalence','(not (= old_cmd new_cmd))','unsat'),
           ('lost-next-owner','(and common current_hit new_owner extent24 (not old_hi))','sat'),
           ('lost-residency','(and common new_owner extent24 (not (and chain next_req rd)) (not old_hi))','sat'),
           ('lost-full-line','(and common current_hit same_primary rd (not full) extent24 '
            '(not (and chain next_req rd)) (not old_hi))','sat'),
           ('wrong-extent','(and common current_hit new_owner extent28 '
            '(not (and chain next_req rd)) (not old_hi))','sat'),
           ('narrow-without-ack','(and cmd_common narrow (not old_cmd))','sat')]
    root.mkdir(); rows=[]
    for name,assertion,expected in cases:
        problem=formal()+'(assert '+assertion+')\n(check-sat)\n'
        query=root/(name+'.smt2'); query.write_text(problem)
        run=subprocess.run(['/usr/bin/z3',str(query)],text=True,capture_output=True,timeout=20)
        log=root/(name+'.log'); log.write_text(run.stdout+run.stderr)
        assert run.returncode==0 and run.stdout.strip()==expected,(name,run.stdout,run.stderr)
        rows.append(dict(name=name,answer=expected,native_exit=run.returncode,
                         query_sha256=sha(query),log_sha256=sha(log)))
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,rows=rows,pins_unchanged=True,
                invocation=os.environ.get('INVOCATION_ID'),whole_core=False,
                abstract_combinational_contract=True,gameplay_ipc=None,fmax_mhz=None)
    (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__': main()
