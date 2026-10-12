#!/usr/bin/env python3
"""Build the measured rem-split candidate with only typed load completions.

No feature flags/latencies are changed. Compile success is not verification.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare_load_read_ack as recipe
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/srt'))
import build_input_norm_core as common

MODEL = '37250c5f8b7350d77b7e102e5fc6b7ebb99c078873534634e84f142c0b779329'
TIMING_AUDIT = '1d4aff92ac2e3011981c139a4c01bb527a26d48f5509988f3a76f64911f6d565'
sha, load, save, stable = common.sha, common.load, common.save, common.stable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'timing', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent, timing = (getattr(args,k).resolve(strict=True) for k in ('parent','timing'))
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert sha(timing/'audit.json') == TIMING_AUDIT
    measured = load(timing/'audit.json')
    assert measured['passed'] and measured['native_exit'] == 0
    assert abs(measured['unplaced_core_estimate_mhz'] - 29.696501752093603) < 1e-9
    assert measured['constraints_mhz'] == dict(core=40, pl=100)
    flags = [s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_FP_LOAD_EARLY_CMD','VEN_SRT_REM_OPERAND_SPLIT','VEN_FP_SHARED',
        'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
        'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    source = parent/'candidate'
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    changed = recipe.transform((source/recipe.PAYLOAD).read_text())
    pins = dict(old['pins'], **measured['pins'])
    for path in (Path(__file__), Path(recipe.__file__), Path(common.__file__),
        parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium', timing/'audit.json'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    out.mkdir()
    shutil.copytree(source, out/'candidate')
    (out/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(out/'candidate')) for p in common.candidate_files(out/'candidate')] == relative
    assert [n for n in relative if sha(source/n) != sha(out/'candidate'/n)] == [recipe.PAYLOAD]
    host = out/('tb_load_read_ack_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, out, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(out/'candidate'/n):sha(out/'candidate'/n) for n in relative})
    save(out/'build-started.json', dict(pins=pins, command=command, definitions=definitions,
        host=str(host), parent=str(parent), parent_model=MODEL, changes=[recipe.PAYLOAD],
        invocation=os.environ['INVOCATION_ID'], gameplay_ipc=None, canonical_gate_passed=False))
    result = dict(passed=False, errors=[], canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    begin = time.monotonic()
    try:
        with (out/'build.log').open('x') as log:
            native = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj = out/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except BaseException as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=stable(pins))
    result['passed'] &= result['pins_unchanged']
    save(out/'build-closed.json', result)
    print(result, flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
