#!/usr/bin/env python3
"""Bounded actual-include equivalence, legacy/system profiles and negative controls."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rtl', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    here = Path(__file__).resolve().parent
    repo = here.parents[1]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    rtl = args.rtl.resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 2*1024**3
    out.mkdir()
    recipe_path = here/'prepare-prefix-ex-regonly.py'
    spec = importlib.util.spec_from_file_location('regonly_recipe', recipe_path)
    recipe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recipe)
    old = (rtl/'core/core_prefix_ex_chain.svh').read_text()
    new = recipe.transform(old)
    packages = [rtl/'ventium_pkg.sv', rtl/'core/ventium_alu_pkg.sv', rtl/'core/ventium_decode_pkg.sv']
    inputs = [*packages, rtl/'core/core_prefix_ex_chain.svh', recipe_path, Path(__file__),
              here/'tb_prefix_ex_regonly.sv', here/'test_prefix_ex_regonly.py',
              repo/'tools/verilator_serial.sh', repo/'tools/build_scope.sh']
    pins = {str(path): sha(path) for path in inputs}

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')

    def write(path, value):
        with path.open('x') as stream:
            stream.write(value)
        pins[str(path)] = sha(path)

    def invoke(label, argv, limit):
        save(label+'.command.json', argv)
        with (out/(label+'.log')).open('x') as log:
            run = subprocess.run(['timeout', '--signal=TERM', '--kill-after=5s', str(limit)+'s', *argv],
                                 stdout=log, stderr=subprocess.STDOUT)
        return run.returncode, (out/(label+'.log')).read_text()

    save('started.json', dict(input_pins=pins, invocation=os.environ.get('INVOCATION_ID'),
                             source_rtl=str(rtl), gameplay_ipc=None))
    start = time.monotonic()
    result = dict(passed=False, rows=[], errors=[], standard_suite=False, gameplay_ipc=None)
    try:
        rc, log = invoke('recipe-tests', ['python3', '-B', str(here/'test_prefix_ex_regonly.py'), '-v'], 30)
        assert rc == 0 and 'Ran 5 tests' in log and '\nOK\n' in log
        for profile, mutation in (('legacy', None), ('system', None),
                                  ('legacy', 'missing-ea-guard'), ('system', 'memory-admitted')):
            label = profile + ('-'+mutation if mutation else '')
            leaf = out/label
            leaf.mkdir()
            text = new
            if mutation == 'missing-ea-guard':
                needle = "(!d_mem_read || (d_addr_mask_known && ((d_addr_mask & gpr_we) == 8'd0)))"
                assert text.count(needle) == 1
                text = text.replace(needle, "1'b1")
            if mutation == 'memory-admitted':
                assert text.count('      !d_mem_read;') == 1
                assert text.count('    !d_mem_read && !d_mem_write && !def16') == 1
                text = text.replace('      !d_mem_read;', "      1'b1;").replace(
                    '    !d_mem_read && !d_mem_write && !def16', '    !d_mem_write && !def16')
            write(leaf/'core_prefix_ex_chain.svh', text)
            # Namespacing only; all reference predicates and register logic stay intact.
            write(leaf/'prefix_ex_reference.svh', old.replace('p54_prefix_ex_', 'reference_prefix_ex_'))
            write(leaf/'tb_prefix_ex_regonly.sv', (here/'tb_prefix_ex_regonly.sv').read_text())
            defs = ['VTM_NO_DPI','VEN_P54_PREFIX_EX_CHAIN','VEN_P54_INT_EXEC_OCC',
                    'VEN_PIPE_SDISPATCH','VEN_PIPE_SDECODE','VEN_L1_AXI','VEN_IC_BRAM',
                    'VEN_FP_PIPE','VEN_FP_PIPE2','VEN_DBG_CORE']
            if profile == 'system':
                defs.append('VEN_P54_PREFIX_EX_SYSTEM')
            command = [str(repo/'tools/verilator_serial.sh'),'--binary','--timing','--assert',
                '-sv','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+x for x in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+x for x in defs], '-I'+str(leaf), '--top-module','tb_prefix_ex_regonly',
                '--Mdir',str(leaf/'obj'),'-j','8',*map(str,packages),str(leaf/'tb_prefix_ex_regonly.sv')]
            rc, log = invoke(label+'-build', command, 180)
            assert rc == 0, (label,'build failed',rc)
            model = leaf/'obj/Vtb_prefix_ex_regonly'
            rc, log = invoke(label+'-run', [str(model)], 30)
            match = re.findall(r'PREFIX-EX-REGONLY-OK checks=(\d+) accepted=(\d+)', log)
            row = dict(profile=profile, mutation=mutation, native_exit=rc, model_sha256=sha(model))
            if mutation:
                assert rc != 0 and 'REGONLY_EQUIV check=' in log and not match, (label,rc,log)
                row['rejected_by_equivalence_assertion'] = True
            else:
                assert rc == 0 and len(match) == 1
                row.update(checks=int(match[0][0]), accepted=int(match[0][1]))
                assert row['checks'] > 330000 and row['accepted'] > 100000
            result['rows'].append(row)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins=pins, pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                      seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged']
        save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
