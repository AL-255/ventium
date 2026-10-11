#!/usr/bin/env python3
"""Exercise the actual private response recipe using the extracted owner TB.

Also preprocess its profile guards: other profiles must retain the old equation.
Those guard checks do not qualify full non-target configurations.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import prepare_pair_response_read_commit as patch
import test_pair_response_read_commit as leaf
import prove_pair_response_read_commit as proof

sha = proof.sha


def fixture(core, mutant):
    # Reuse the tested owner/request stimulus, but replace its prospective
    # equations with the actual recipe, including its live witnesses/guards.
    text = leaf.fixture(core, mutant)
    commit = leaf.equation(core, 'pipe_int_commit', 'fsm_case_enabled')
    read = commit.replace('pipe_int_commit =', 'pair_read_commit =').replace(
        '!pipe_mem_wait', '!pipe_store_req && (!pipe_load_req || mem_read_ack)')
    old = leaf.equation(core, 'mem_pair_rsp_ready', '!pipe_mem_v_hit_q').replace(
        'mem_pair_rsp_ready =', 'old_ready =')
    new = old.replace('old_ready =', 'new_ready =').replace('pipe_int_commit', 'pair_read_commit')
    block = patch.replacement(core).replace('mem_pair_rsp_ready', 'new_ready')
    if mutant == 'missing-read-ack':
        read = read.replace('(!pipe_load_req || mem_read_ack)', "1'b1")
        block = block.replace('(!pipe_load_req || mem_read_ack)', "1'b1")
    elif mutant == 'raw-fragment-ack':
        read = read.replace('mem_read_ack', 'bus_read_ack')
        block = block.replace('(!pipe_load_req || mem_read_ack)', '(!pipe_load_req || bus_read_ack)')
    elif mutant == 'lost-orphan-drain':
        new = new.replace('(!pipe_mem_v_hit_q || pair_read_commit)', 'pair_read_commit')
        block = block.replace('(!pipe_mem_v_hit_q || pair_readonly_int_commit)', 'pair_readonly_int_commit')
    original = read+old+new
    assert text.count(original) == 1
    return text.replace(original, old+block)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    source = args.core.resolve(strict=True); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    core = source.read_text(); candidate = patch.transform(core)
    for wrong in (core+'\n', candidate):
        try: patch.transform(wrong)
        except ValueError: pass
        else: raise AssertionError('source drift/reapplication accepted')
    pins = {str(p): sha(p) for p in (source, Path(__file__).resolve(),
            Path(patch.__file__).resolve(), Path(leaf.__file__).resolve(), Path(proof.__file__).resolve())}
    root.mkdir(); (root/'core.sv').write_text(candidate)
    result = dict(passed=False,pins=pins,rows=[],guard_rows=[],whole_core=False,
        candidate_sha256=sha(root/'core.sv'),gameplay_ipc=None,fmax_mhz=None)
    started = time.monotonic()
    try:
        original = patch.assignment(core, 'mem_pair_rsp_ready', '!pipe_mem_v_hit_q')
        for label, flags in (
                ('raw', ['-DVEN_RAW_V_READ_PRIME']),
                ('nonraw', []),
                ('dualprime', ['-DVEN_RAW_V_READ_PRIME','-DVEN_P54_DUAL_LOAD_PRIME']),
                ('regmem', ['-DVEN_RAW_V_READ_PRIME','-DVEN_P54_DUAL_LOAD_PRIME','-DVEN_P54_REGMEM_PRIME'])):
            path = root/(label+'.sv'); output = root/(label+'.preprocessed.sv')
            path.write_text('module guard_probe;\n'+patch.replacement(core)+'endmodule\n')
            native = subprocess.run(['iverilog','-g2012','-E',*flags,'-o',output,path],
                                    capture_output=True,text=True,timeout=10)
            assert native.returncode == 0, native.stderr
            expanded = output.read_text()
            equation = patch.assignment(expanded,'mem_pair_rsp_ready','!pipe_mem_v_hit_q')
            if label == 'raw':
                assert equation == original.replace('pipe_int_commit','pair_readonly_int_commit')
                assert 'logic pair_readonly_int_commit;' in expanded
            else:
                assert equation == original and 'pair_readonly_int_commit' not in expanded
            result['guard_rows'].append(dict(label=label,native_exit=native.returncode,
                artifacts={str(p):sha(p) for p in (path,output)}))
        for mutant in (None,'missing-read-ack','raw-fragment-ack','lost-orphan-drain','lost-fault-clear'):
            label = mutant or 'positive'; folder=root/label; folder.mkdir()
            path=folder/'tb.sv'; binary=folder/'a.out'; path.write_text(fixture(core,mutant))
            with (folder/'build.log').open('x') as stream:
                built=subprocess.run(['iverilog','-g2012','-DVEN_FP_PIPE',
                    '-DVEN_PIPE_MEM_CHAIN','-DVEN_PIPE_REG_LOAD_PRIME','-DVEN_RAW_V_READ_PRIME',
                    '-DVEN_P54_DUAL_LOAD_PAIR','-s','tb','-o',binary,path],
                    stdout=stream,stderr=subprocess.STDOUT,timeout=15)
            assert built.returncode == 0, label
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run(['vvp',binary],stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            log=(folder/'run.log').read_text()
            result['rows'].append(dict(label=label,native_exit=native.returncode,log=log,
                artifacts={str(p):sha(p) for p in (path,binary,folder/'build.log',folder/'run.log')}))
            assert (native.returncode != 0 and 'PAIR-RESPONSE' in log) if mutant else (
                native.returncode == 0 and 'PAIR-RESPONSE-LEAF-OK' in log), result['rows'][-1]
        result['passed']=True
    finally:
        result.update(seconds=time.monotonic()-started,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='pins'},indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
