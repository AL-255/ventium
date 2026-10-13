"""Abstract two-state capture/return exclusion, backed by extracted RTL tests.

Not automatic SystemVerilog formal elaboration or a sequential cache proof.
Address equality, tag hits and unconstraining eligibility are independent
Boolean inputs. Preserve the shared saved-window/ownership relationships.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

from test_window_current_reuse import sha


def formal():
    text='(set-logic QF_BV)\n'
    names=('dual capture_enabled prime_enabled store_enabled windows two_windows '
           'req0 req1 req we rdarmed rdmatch nextlookup prime_lookup_other '
           'idle early stream flush snoop golden cache current_hit selected_hit '
           'window_valid shadow_valid primary_line shadow_line extent code '
           'fresh_shape prime_other store_other now_other lane_cache lane_tag lane_size')
    for n in names.split():text+=f'(declare-const {n} Bool)\n'
    def term(name,body):
        nonlocal text
        text+=f'(define-fun {name} () Bool {body})\n'
    term('vonly','(and req1 (not req0))')
    term('saved','(and windows (not flush) extent (or (and window_valid primary_line) '
         '(and two_windows shadow_valid shadow_line)))')
    term('reuse','(and saved (not nextlookup) (not stream) (not early) idle req '
         '(not we) cache (not golden) (not snoop) selected_hit (not code))')
    term('fresh_base','(and capture_enabled vonly req (not we) cache (not golden) '
         '(not rdarmed) idle (not early) (not stream) (not snoop) current_hit fresh_shape (not code))')
    term('fresh','(and fresh_base (not saved))')
    term('legacy_base','(and req (not we) rdmatch cache)')
    term('legacy','(and legacy_base (not (and dual vonly)))')
    term('prime_base','(and capture_enabled prime_enabled vonly prime_lookup_other prime_other)')
    term('prime','(and prime_base (not req))')
    term('store_base','(and capture_enabled store_enabled vonly req store_other)')
    term('store','(and store_base we)')
    term('common','(and (or req0 req1) idle (not early) (not stream) (not flush) (not snoop) (not golden))')
    term('free','(and (not req) (not rdarmed) (not nextlookup))')
    term('lookup','(and common (or free (and legacy (not nextlookup)) fresh prime store))')
    term('now','(and now_other req1 req (not we) cache reuse)')
    term('hit','(and lookup lane_cache lane_tag lane_size)')
    term('old','(and hit (not now))')
    term('new','(and hit (not (and now (or (not dual) req0))))')
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();leaf=args.leaf.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    start=json.loads((leaf/'started.json').read_text());done=json.loads((leaf/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors'] and done['source_scope_exact']
    assert [(r['name'],r['native_exit']) for r in done['rows']]==[(n,0) for n in
        ('full','standalone','no-capture','no-chain','primary-only','no-windows','prime','store-load')]+[
        ('lost-two-lane-priority',1)]
    assert all('PAIR-NOW-CAPTURE-OK checks=149509 ' in r['coverage'] for r in done['rows'] if not r['mutant'])
    pins=dict(start['pins'])
    for row in done['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__).resolve(),leaf/'started.json',leaf/'closed.json',Path('/usr/bin/z3')):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    cases=[('v-only-exclusion','(and dual vonly now lookup)','unsat'),
           ('hit-equivalence','(not (= old new))','unsat'),
           ('saved-excludes-fresh','(and now fresh)','unsat'),
           ('request-excludes-prime','(and now prime)','unsat'),
           ('lost-two-lane-priority','(and hit now req0)','sat'),
           ('lost-legacy-v-only-guard','(and dual vonly now common legacy_base (not nextlookup))','sat'),
           ('lost-fresh-saved-guard','(and dual vonly now common fresh_base)','sat'),
           ('lost-prime-request-guard','(and dual vonly now common prime_base)','sat'),
           ('lost-store-write-guard','(and dual vonly now common store_base)','sat')]
    root.mkdir();rows=[]
    for name,assertion,expected in cases:
        query=root/(name+'.smt2');query.write_text(formal()+'(assert '+assertion+')\n(check-sat)\n')
        native=subprocess.run(['/usr/bin/z3',str(query)],capture_output=True,text=True,timeout=10)
        log=root/(name+'.log');log.write_text(native.stdout+native.stderr)
        assert native.returncode==0 and native.stdout.strip()==expected,(name,native.stdout,native.stderr)
        rows.append(dict(name=name,answer=expected,native_exit=native.returncode,
                         query_sha256=sha(query),log_sha256=sha(log)))
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,pins_unchanged=True,rows=rows,invocation=os.environ['INVOCATION_ID'],
        abstract_combinational_contract=True,automatic_rtl_formal=False,sequential_cache=False,
        whole_core=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    with (root/'closed.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__':main()
