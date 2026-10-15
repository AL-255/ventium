"""Derive bounded, provenance-pinned leaf/core jobs for the narrower cofactor.

Reuse the retained current-U experiment's build machinery, not its rejected
interface policy. The leaf has no input contract filter: compare identical
pins/outputs on all legal clocks. Generic next-read conflicts stay covered;
the optimized contract has an explicit failing conflict control.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess

import prepare_pair_next_disjoint as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def leaf_driver():
    text = (HERE/'run_current_u_pair.py').read_text()
    text = recipe.once(text, 'import prepare_current_u_pair as recipe',
                       'import prepare_pair_next_disjoint as recipe')
    text = recipe.once(text, 'HERE = Path(__file__).resolve().parent', f'HERE = Path({str(HERE)!r})')
    # Generate the SAME stimulus and parent observer used in generic mode.
    # No filtering of pair_req_valid or conditional comparison is permitted.
    start = text.index('    if special:\n        observe =')
    end = text.index('    controls =', start)
    text = text[:start] + text[end:]
    start = text.index('    if special:\n        leaf =')
    end = text.index('    marker =', start)
    text = text[:start] + '''    if special:
        # These two deliberate next/pair conflicts belong only to the
        # generic-client pass, and to the separate rejection test below.
        leaf = recipe.once(leaf, 'for(int committed=0;committed<2;committed++)',
                           'for(int committed=0;committed<0;committed++)')
''' + text[end:]
    text = text.replace('PAIR_CURRENT_U_ONLY', 'PAIR_NEXT_DISJOINT')
    text = text.replace('{0 if special else 2}', '{2}')
    text = recipe.once(text,
        "('generic',False,set(),False),('current-u',True,set(),False),\n"
        "                ('current-u-lutram-two-window',True,{'VEN_L1D_TAG_LUTRAM','VEN_L1D_TWO_WINDOW_REUSE'},False),\n"
        "                ('mutant-unowned',True,set(),True)",
        "('generic',False,set(),False),('disjoint',True,set(),False),\n"
        "                ('conflict-negative',True,set(),True)")
    start = text.index('            if mutant:\n')
    end = text.index("            (folder/'ven_l1d.sv')",start)
    text = text[:start] + text[end:]
    text = recipe.once(text,
        "            (folder/'tb_l1d_mem_chain.sv').write_text(fixture(original.ports(pp),special))",
        "            bench = fixture(original.ports(pp),special)\n"
        "            if mutant:\n"
        "                bench = recipe.once(bench, \"    #1;\\n    if (c_req || pair_req_ready\",\n"
        "                    \"    c_next_req=1; c_next_commit=0; c_next_addr='h1000;\\n\"\n"
        "                    \"    #1;\\n    if (c_req || pair_req_ready\")\n"
        "            (folder/'tb_l1d_mem_chain.sv').write_text(bench)")
    text = recipe.once(text,
        "assert rc != 0 and ('CURRENT-U-EMPTY-SLOT' in log or 'CUT_EQUIV' in log or 'CURRENT-U-PAIR' in log),log",
        "assert rc != 0 and ('PAIR-NEXT-DISJOINT' in log or 'PAIR-OVERLAP-ACK' in log or 'CUT_EQUIV pair_req_ready' in log),log")
    text = recipe.once(text,
        "assert 'checks=538 fresh=448 same_bank=64 held=1536' in log,log",
        "assert f'checks={536 if special else 538} fresh=448 same_bank=64 held=1536' in log,log")
    text = text.replace('len(rows)==4', 'len(rows)==3')
    text = text.replace("contract_filter='c_req && !c_we && pair_req_valid == 2b10',\n        unconditional_equivalence=False",
                        "contract_filter=None,\n        unconditional_equivalence=False, legal_domain_equivalence=True")
    # Pin the module imported by the recipe as well as its own source.
    text = recipe.once(text, "HERE/'tb_l1d_mem_chain.sv', HERE/'l1_legacy_capture_cut_leaf.svh',",
        "HERE/'prepare_current_u_pair.py', HERE/'tb_l1d_mem_chain.sv', HERE/'l1_legacy_capture_cut_leaf.svh',")
    return text


def core_driver():
    text = (HERE/'build_current_u_pair_core.py').read_text()
    text = text.replace('import prepare_current_u_pair as recipe',
                        'import prepare_pair_next_disjoint as recipe')
    text = recipe.once(text, 'REPO = Path(__file__).resolve().parents[2]', f'REPO = Path({str(REPO)!r})')
    text = text.replace("'current-u-pair-leaf-r1'", "'pair-next-disjoint-leaf-r6'")
    text = recipe.once(text,
        "('generic',0),('current-u',0),('current-u-lutram-two-window',0),('mutant-unowned',1)",
        "('generic',0),('disjoint',0),('conflict-negative',1)")
    text = text.replace("leaf/'current-u/ven_l1d.sv'", "leaf/'disjoint/ven_l1d.sv'")
    text = text.replace("'tb_current_u_pair_'", "'tb_pair_next_disjoint_'")
    text = text.replace('Reject standalone/no-current-U sideband requests only in the core current-U client',
                        'Retain idle V admission; assert pair/next lookup exclusion in selected core client')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('leaf','core'))
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    text = leaf_driver() if args.stage == 'leaf' else core_driver()
    ast.parse(text)
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream: stream.write(text)
    paths = [Path(__file__).resolve(), Path(recipe.__file__).resolve(),
             HERE/'prepare_current_u_pair.py',
             HERE/('run_current_u_pair.py' if args.stage=='leaf' else 'build_current_u_pair_core.py'), driver]
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    pins = {str(p):sha(p) for p in paths}
    with root.with_suffix('.inputs.json').open('x') as stream: json.dump(pins,stream,indent=2)
    env = dict(os.environ, PYTHONPATH=str(HERE))
    child = subprocess.run(['/usr/bin/python3','-B',str(driver),'--out',str(root)],
                           env=env,pass_fds=(9,),timeout=600)
    assert all(sha(Path(p))==h for p,h in pins.items())
    return child.returncode


if __name__ == '__main__': raise SystemExit(main())
