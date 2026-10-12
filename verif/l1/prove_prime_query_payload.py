"""All-bit payload-selector proof after the native extracted-equation miter.

Eligibility is over-approximated: live offers exclude the retained owner,
retained offers require it, and AGI/reference offers require their selectors.
This is a combinational contract proof, not full-core temporal equivalence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

import prepare_prime_query_payload as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def query(mode):
    text = '(set-logic QF_BV)\n'
    for name in ('valid', 'fp', 'held', 'fresh', 'ordinary', 'prepare', 'retained',
                 'agi_select', 'ref_select', 'agi_guard', 'ref_guard', 'query_byte', 'saved_byte'):
        text += '(declare-const '+name+' Bool)\n'
    for name, width in (('query_addr',32),('saved_addr',32),('agi_width',3),('ref_strb',4)):
        text += f'(declare-const {name} (_ BitVec {width}))\n'
    terms = {
        'prime': ('Bool', '(and (not valid) (or fp held fresh ordinary) prepare)'),
        'request': ('Bool', '(or (and agi_select agi_guard) (and ref_select ref_guard) (and valid retained) prime)'),
        'old_select': ('Bool', '(or agi_select ref_select prime)'),
        'new_select': ('Bool', '(or agi_select ref_select (not valid))'),
        'old_addr': ('(_ BitVec 32)', '(ite old_select query_addr saved_addr)'),
        'new_addr': ('(_ BitVec 32)', '(ite new_select query_addr saved_addr)'),
        'agi_strb': ('(_ BitVec 4)', '(ite (= agi_width #b001) #x1 #xf)'),
        'old_width': ('Bool', '(ite prime query_byte saved_byte)'),
        'new_width': ('Bool', '(ite (not valid) query_byte saved_byte)'),
        'old_strb': ('(_ BitVec 4)', '(ite agi_select agi_strb (ite ref_select ref_strb (ite old_width #x1 #xf)))'),
        'new_strb': ('(_ BitVec 4)', '(ite agi_select agi_strb (ite ref_select ref_strb (ite new_width #x1 #xf)))'),
    }
    if mode == 'always-live':
        terms['new_select'] = ('Bool', 'true')
        terms['new_width'] = ('Bool', 'query_byte')
    elif mode == 'always-retained':
        terms['new_select'] = ('Bool', '(or agi_select ref_select)')
        terms['new_width'] = ('Bool', 'saved_byte')
    elif mode == 'wrong-query-width':
        terms['new_width'] = ('Bool', '(ite (not valid) (not query_byte) saved_byte)')
    elif mode == 'lost-agi-width':
        terms['new_strb'] = ('(_ BitVec 4)', '(ite ref_select ref_strb (ite new_width #x1 #xf))')
    elif mode == 'allow-live-retained-collision':
        terms['prime'] = ('Bool', '(and (or fp held fresh ordinary) prepare)')
    for name, (kind, expression) in terms.items():
        text += f'(define-fun {name} () {kind} {expression})\n'
    active = '(not request)' if mode == 'idle-difference' else 'request'
    return text+f'(assert (and {active} (or (not (= old_addr new_addr)) (not (= old_strb new_strb)))))\n(check-sat)\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve(); leaf = args.leaf.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    closed = json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    assert [(row['label'],row['native_exit']) for row in closed['rows']] == [
        ('positive',0),('always-live',1),('always-retained',1),('wrong-query-width',1),('lost-agi-width',1)]
    pins = dict(closed['pins'])
    for row in closed['rows']: pins.update(row['artifacts'])
    for path in (leaf/'closed.json',leaf/'core_mem_chain.svh',Path(__file__).resolve()):
        pins[str(path)] = sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    parent = [Path(p) for p,h in closed['pins'].items() if h == recipe.PARENT]
    assert len(parent) == 1
    assert recipe.transform(parent[0].read_text()) == (leaf/'core_mem_chain.svh').read_text()
    root.mkdir(); rows = []
    for mode in ('positive','idle-difference','always-live','always-retained',
                 'wrong-query-width','lost-agi-width','allow-live-retained-collision'):
        path = root/(mode+'.smt2'); path.write_text(query(mode))
        proc = subprocess.run(['z3',str(path)],text=True,capture_output=True,timeout=10)
        log = root/(mode+'.log'); log.write_text(proc.stdout+proc.stderr)
        expected = 'unsat' if mode == 'positive' else 'sat'
        assert proc.returncode == 0 and proc.stdout.strip() == expected, (mode,proc.stdout,proc.stderr)
        rows.append(dict(mode=mode,native_exit=proc.returncode,answer=expected,
                         query_sha256=sha(path),log_sha256=sha(log)))
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(passed=True,pins=pins,pins_unchanged=True,rows=rows,
                  abstract_combinational_contract=True,whole_core=False,
                  invocation=os.environ.get('INVOCATION_ID'),
                  gameplay_ipc=None,fmax_mhz=None)
    (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__ == '__main__': main()
