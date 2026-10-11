#!/usr/bin/env python3
"""All-Boolean guard proof for the read-only hint commit cofactor.

This is an abstract predicate proof, not a processor proof. All additional
decode/permission/branch/fault conditions are arbitrary inputs. The adjacent
native test executes the actual extracted source equations independently.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import prepare_mc_read_commit as patch


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def query(mutant=None):
    flags = ('spipe active we valid u_store u_mem u_fp request_ok live_ok '
             'fsm fp_block boundary offer_extra prepare branch_guard fp_extra '
             'held_extra fresh_extra ordinary_extra read_bus write_bus hold '
             'agi ref fp_admit').split()
    text = '(set-logic QF_UF)\n'
    for name in flags:
        text += f'(declare-const {name} Bool)\n'
    terms = {
        'newload': '(and spipe (not active) request_ok u_mem (not u_store))',
        'newstore': '(and spipe (not active) request_ok u_store)',
        'newmem': '(or newload newstore)',
        'load': '(ite active (and spipe (not we)) newload)',
        'store': '(ite active (and spipe we) newstore)',
        'buswe': '(ite spipe (and (not load) store) true)',
        'ack': '(and (ite buswe write_bus read_bus) (not hold))',
        'readack': '(and read_bus (not hold))',
        'base': '(and spipe fsm (not fp_block) (or active (and (not active) live_ok (not u_fp))))',
        'oldcommit': '(and base (not (and (or load store) (not ack))))',
        'newcommit': '(and base (not store) (or (not load) readack))',
        'offer': '(and valid boundary active (not we) offer_extra)',
        'fpprime': '(and u_fp (not valid) (not active) fp_extra)',
        'held': '(and spipe active (not we) (not valid) held_extra)',
        'fresh': '(and (not active) (not valid) newload fresh_extra)',
        'ordinary': '(and (not valid) (not active) (not newmem) ordinary_extra)',
        'prime': '(and (or fpprime held fresh ordinary) prepare)',
        'old': '(or agi ref (and (or offer (and prime branch_guard)) (or oldcommit (and fpprime fp_admit))))',
        'new': '(or agi ref (and (or offer (and prime branch_guard)) (or newcommit (and fpprime fp_admit))))',
    }
    if mutant == 'missing-read-ack':
        terms['newcommit'] = terms['newcommit'].replace('(or (not load) readack)', 'true')
    elif mutant == 'raw-fragment-ack':
        terms['newcommit'] = terms['newcommit'].replace('readack', 'read_bus')
    elif mutant == 'lost-fp-admission':
        terms['new'] = terms['new'].replace('(and fpprime fp_admit)', 'false')
    elif mutant == 'allow-store-prime':
        terms['ordinary'] = terms['ordinary'].replace('(not newmem)', 'true')
    for name, expression in terms.items():
        text += f'(define-fun {name} () Bool {expression})\n'
    return text+'(assert (not (= old new)))\n(check-sat)\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--leaf', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve(); source = args.source.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    core, header = [(source/name).read_text() for name in ('core.sv','core_mem_chain.svh')]
    candidate = patch.transform(core,header)
    leaf = args.leaf.resolve(strict=True)
    before = json.loads((leaf/'closed.json').read_text())
    assert before['passed'] and before['pins_unchanged']
    assert candidate == (leaf/'core_mem_chain.svh').read_text()
    assert [(r['label'],r['native_exit']) for r in before['rows']] == [
        ('positive',0),('missing-read-ack',1),('raw-fragment-ack',1),('lost-fp-admission',1)]
    pins = dict(before['pins'])
    for row in before['rows']:
        pins.update(row['artifacts'])
    for path in (Path(__file__).resolve(),leaf/'closed.json',leaf/'core_mem_chain.svh'):
        pins[str(path)] = sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir(); rows = []
    for mutant in (None,'missing-read-ack','raw-fragment-ack','lost-fp-admission','allow-store-prime'):
        path = root/((mutant or 'positive')+'.smt2')
        path.write_text(query(mutant))
        proc = subprocess.run(['z3',str(path)],text=True,capture_output=True,timeout=10)
        (root/((mutant or 'positive')+'.log')).write_text(proc.stdout+proc.stderr)
        assert proc.returncode == 0 and proc.stdout.strip() == ('sat' if mutant else 'unsat'), (mutant,proc.stdout,proc.stderr)
        rows.append(dict(label=mutant or 'positive',native_exit=proc.returncode,
                         answer=proc.stdout.strip(),query_sha256=sha(path)))
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(passed=True,rows=rows,pins=pins,pins_unchanged=True,
                  abstract_predicate_proof=True,whole_core=False,gameplay_ipc=None,fmax_mhz=None)
    (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}))


if __name__ == '__main__':
    main()
