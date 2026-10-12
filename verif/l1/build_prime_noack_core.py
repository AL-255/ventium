#!/usr/bin/env python3
"""Private same-profile core integration after the native priming miter closes."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import build_pair_now_core as parent_builder
import prepare_prime_noack as recipe

common = parent_builder.common
sha, load, save, stable = common.sha, common.load, common.save, common.stable
REPO = Path(__file__).resolve().parents[2]
PARENT_MODEL = 'b84cc5b4618defd2067c8c37b2e084229a3e6759a2358eab4c570e035f5eceb4'


def check_leaf(result):
    assert result['passed'] and result['pins_unchanged'] and not result['errors']
    assert result['build_exit'] == 0
    rows = result['rows']
    assert len(rows) == 4 and [r['mutant'] for r in rows] == [0, 1, 2, 3]
    assert rows[0]['native_exit'] == 0 and all(r['native_exit'] != 0 for r in rows[1:])
    counts = rows[0]['counts']
    assert counts['samples'] >= 6_000_000
    assert all(counts[k] > 0 for k in ('fp', 'agi', 'ref_int', 'ref_fp', 'noack', 'held', 'blocked'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built, proof = load(parent/'build-started.json'), load(parent/'build-closed.json'), load(leaf/'closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == PARENT_MODEL
    check_leaf(proof)
    assert stable(old['pins']) and stable(proof['pins'])
    pins = dict(old['pins'], **proof['pins'])
    for row in proof['rows']:
        log = leaf/('run-'+str(row['mutant'])+'.log')
        assert sha(log) == row['log_sha256']
        assert ('PRIME_EQUIV' if row['mutant'] else 'PRIME-NOACK-OK') in log.read_text()
        pins[str(log)] = sha(log)
    binary = leaf/'obj/Vtb_prime_noack'
    assert sha(binary) == proof['binary_sha256']
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    changed = recipe.transform({p: (parent/'candidate'/p).read_text() for p in recipe.HASHES})
    assert all(text == (leaf/'candidate'/name).read_text() for name, text in changed.items())
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = re.findall(r'\+define\+(\w+)', flags)
    assert len(defs) == len(set(defs)) == 150 and '--assert' in flags and 'VL_J=32' in old['command']
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_RAW_AGI_PRIME', 'VEN_REF_OPERAND_PRIME',
            'VEN_P54_DUAL_LOAD_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR'} <= set(defs)
    assert not {'SYNTHESIS', 'VTM_NO_DPI'} & set(defs)
    for p in (Path(__file__), Path(recipe.__file__), Path(common.__file__), Path(parent_builder.__file__),
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
              leaf/'closed.json', leaf/'started.json', binary):
        pins[str(p)] = sha(p)
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    for name, text in changed.items():
        (root/'candidate'/name).write_text(text)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [p for p in relative if sha(parent/'candidate'/p) != sha(root/'candidate'/p)] == sorted(recipe.HASHES)
    host = root/('tb_prime_noack_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    prepared = dict(command=command, pins=pins, host=str(host), definitions=defs,
                    parent=str(parent), parent_model=PARENT_MODEL, changes=sorted(recipe.HASHES),
                    leaf=str(leaf), compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None)
    save(root/'prepared.json', prepared)
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(prepared, compiler_started=True,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()
    result = dict(passed=False, errors=[], standard_suite=False, hardware_acceptance=False,
                  canonical_gate_passed=False, gameplay_ipc=None)
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=660)
        result['native_exit'] = child.returncode
        assert child.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(pins), seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(result, flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
