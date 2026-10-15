"""Build only the four-file timing composition, with both leaf proofs pinned.

Reuse the checked direct-source builder and native 32-job lifecycle. A new
private harness basename prevents VPATH reuse of another model's host object.
This does not launch Vivado, a full-system workload, or acceptance runs.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess

import prepare_fetch_pair_next as recipe
import run_pair_next_disjoint as parent

HERE = Path(__file__).resolve().parent


def core_driver():
    text = parent.core_driver()
    once = recipe.pair.once
    text = once(text, 'import prepare_pair_next_disjoint as recipe',
                'import prepare_fetch_pair_next as recipe')
    text = once(text, "    parent = DATA/'prefix-payload-core-r1'",
        "    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1\n"
        "    parent = DATA/'prefix-payload-core-r1'")
    text = once(text, "    assert native.stable(checked['pins'])\n", """    assert native.stable(checked['pins'])
    fetch_leaf = DATA/'fetch-fragment-leaf-r5'
    fetch_checked = native.load(fetch_leaf/'closed.json')
    assert fetch_checked['passed'] and fetch_checked['pins_unchanged'] and not fetch_checked['errors']
    assert fetch_checked['profiles'] == [dict(demand16=d,checks=8529920,mutants_failed=2) for d in (False,True)]
    assert [p['result'] for p in fetch_checked['proofs']] == ['unsat','sat','sat','sat']
    assert len(fetch_checked['native']) == 12 and native.stable(fetch_checked['pins'])
    assert all(native.sha(row['log']) == row['sha256'] and row['actual_wait'] and row['reaped']
               and row['affinity'] == list(range(13,17)) for row in fetch_checked['native'])
""")
    text = once(text, "    pins = dict(checked['pins'])\n", """    pins = dict(checked['pins'])
    pins.update(fetch_checked['pins'])
    pins.update({row['log']:row['sha256'] for row in fetch_checked['native']})
    for path in (fetch_leaf/'closed.json', Path(recipe.fetch.__file__), Path(recipe.pair.__file__),
                 REPO/'verif/l1/prepare_current_u_pair.py',
                 REPO/'verif/l1/run_pair_next_disjoint.py',
                 REPO/'verif/l1/build_current_u_pair_core.py',
                 REPO/'verif/l1/build_fetch_pair_next_core.py'):
        pins[str(path.resolve())] = native.sha(path)
""")
    text = once(text,
        "    assert (root/'candidate/rtl/mem/ven_l1d.sv').read_text() == (leaf/'disjoint/ven_l1d.sv').read_text()",
        "    assert (root/'candidate/rtl/mem/ven_l1d.sv').read_text() == (leaf/'disjoint/ven_l1d.sv').read_text()\n"
        "    assert (root/'candidate'/recipe.fetch.FILE).read_text() == (fetch_leaf/'core.sv').read_text()")
    text = once(text, "'tb_pair_next_disjoint_'", "'tb_fetch_pair_next_'")
    text = once(text,
        'Retain idle V admission; assert pair/next lookup exclusion in selected core client',
        'Compose exact fetch/fragment and pair/next cofactors; both original equivalence assertions remain active')
    ast.parse(text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    root = parser.parse_args().out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    text = core_driver()
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write(text)
    paths = (Path(__file__), Path(recipe.__file__), Path(recipe.fetch.__file__),
             Path(recipe.pair.__file__), Path(parent.__file__),
             HERE/'prepare_current_u_pair.py', HERE/'build_current_u_pair_core.py', driver)
    sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
    pins = {str(path.resolve()):sha(path) for path in paths}
    with root.with_suffix('.inputs.json').open('x') as stream:
        json.dump(pins, stream, indent=2)
    child = subprocess.run(['/usr/bin/python3','-B',str(driver),'--out',str(root)],
        env=dict(os.environ,PYTHONPATH=str(HERE)),pass_fds=(9,),timeout=600)
    assert all(sha(path)==digest for path,digest in pins.items())
    return child.returncode


if __name__ == '__main__':
    raise SystemExit(main())
