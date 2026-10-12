#!/usr/bin/env python3
"""Integrate the tested SRT tree and paired-response cut into the MC candidate.

Only two private source files change. Both changes have independent leaf tests;
the measured SRT and V-response paths justify combining them for whole-core
qualification. This is a timing experiment, not canonical or FPGA acceptance.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import build_input_norm_core as common
from prepare_input_norm_tree import transform

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import build_pair_response_read_core as pair
MODEL = '64dadfc92c708c49d45e8c0f3b7704e1c24dff48f8d525956dc4624946a07695'
MC_HEADER = 'fd0325d25511950f6761e73f3b2b9ce6ea8ec81c38692203b048954de65ecd5c'
TARGET = 'rtl/fpu/fpu_srt_div.sv'
TARGETS = ['rtl/core/core.sv', TARGET]
sha, load, save, stable = common.sha, common.load, common.save, common.stable


def check_evidence(engine, helper):
    for row, mode in ((engine, 'engine'), (helper, 'helper')):
        assert row['passed'] and row['pins_unchanged'] and not row['errors']
        assert row['mode'] == mode and not row['whole_core']
    assert [(r['label'], r['native_exit']) for r in engine['rows']] == [
        ('positive-build', 0), ('positive', 0), ('bad-sqrt-build', 0), ('bad-sqrt', 1)]
    assert [(r['label'], r['native_exit']) for r in helper['rows']] == [
        ('positive-proof', 0), ('positive-build', 0), ('positive', 0),
        ('wrong-zero-proof', 0), ('wrong-zero-build', 0), ('wrong-zero', 1),
        ('wrong-half-proof', 0), ('wrong-half-build', 0), ('wrong-half', 1)]


def prepare(args, root):
    parent, leaf, helper, pair_leaf, pair_proof = [getattr(args, key).resolve(strict=True)
        for key in ('parent', 'leaf', 'helper', 'pair_leaf', 'pair_proof')]
    assert not root.exists()
    before, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    timing_dir = parent.parent/'clock-r2'
    timing, closed = load(timing_dir/'audit.json'), load(timing_dir/'closed.json')
    assert timing['passed'] and timing['native_exit'] == closed['native_exit'] == 0
    assert not timing['routed'] and timing['physical_frequency_mhz'] is None
    assert timing['constraints_mhz'] == {'pl': 100, 'core': 40}
    assert abs(timing['unplaced_core_estimate_mhz'] - 29.584048281166794) < 1e-8
    assert closed['inputs_unchanged'] and closed['resource_stop'] is None
    assert closed['controller_failure'] is None
    assert stable(timing['pins'])
    owner = timing['retained_owner']
    actual = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-mc-read-clock-r2-oct11.service',
        '-pInvocationID', '-pSubState', '-pMainPID', '-pExecMainStatus',
        '-pActiveState', '-pResult'], text=True).splitlines())
    assert actual == owner and actual['MainPID'] == '0' and actual['ExecMainStatus'] == '0'
    assert actual['InvocationID'] == 'f34d771a7c8e46448d1763059ee10d9d'

    engine, functions = load(leaf/'closed.json'), load(helper/'closed.json')
    check_evidence(engine, functions)
    response, ownership = load(pair_leaf/'closed.json'), load(pair_proof/'closed.json')
    pair.check_rows(response, ownership)
    pins = {**before['pins'], **engine['pins'], **functions['pins'],
            **response['pins'], **ownership['pins']}
    for row in response['rows'] + response['guard_rows'] + ownership['rows']:
        pins.update(row['artifacts'])
    for row in response['rows']:
        assert (pair_leaf/row['label']/'run.log').read_text() == row['log']
    for folder, evidence in ((leaf, engine), (helper, functions)):
        for row in evidence['rows']:
            path = folder/(row['label']+'.log')
            assert sha(path) == row['log_sha256']
            pins[str(path)] = sha(path)
    assert 'SRT-INPUT-NORM-MITER-OK samples=4544 checks=162282 resets=24' in (leaf/'positive.log').read_text()
    assert 'SRT_INPUT_STATE_MISMATCH' in (leaf/'bad-sqrt.log').read_text()
    assert 'SRT-INPUT-HELPER-OK count=378852 fourstate=16514' in (helper/'positive.log').read_text()

    source = parent/'candidate'
    assert sha(source/'rtl/core/core_mem_chain.svh') == MC_HEADER
    changed = transform((source/TARGET).read_text())
    assert changed == (leaf/'candidate.sv').read_text()
    changed_core = pair.patch.transform((source/'rtl/core/core.sv').read_text())
    assert changed_core == (pair_leaf/'core.sv').read_text()
    assert response['candidate_sha256'] == sha(pair_leaf/'core.sv')
    packages = [Path(p) for p in engine['pins'] if Path(p).name == 'fpu_x87_pkg.sv']
    assert len(packages) == 1 and sha(packages[0]) == sha(source/'rtl/fpu/fpu_x87_pkg.sv')
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == before['pins'][str(p)] for p in files)
    frozen = parent.parent/'fpga-r1/ventium'
    assert sha(frozen/TARGET) == sha(source/TARGET)
    assert sha(frozen/'rtl/core/core.sv') == sha(source/'rtl/core/core.sv')
    assert sha(frozen/'rtl/core/core_mem_chain.svh') == MC_HEADER
    flags = next(s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 150 and '--assert' in flags
    assert 'VL_J=32' in before['command']
    assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_P54_DUAL_LOAD_PRIME',
                'VEN_P54_REGMEM_PRIME'} & set(definitions)
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI', 'VEN_FP_LOAD_EARLY_CMD',
            'VEN_RAW_V_READ_PRIME', 'VEN_P54_DUAL_LOAD_PAIR'} <= set(definitions)
    for path in (Path(__file__), Path(common.__file__),
                 Path(__file__).with_name('prepare_input_norm_tree.py'),
                 parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
                 timing_dir/'audit.json', timing_dir/'closed.json',
                 leaf/'closed.json', helper/'closed.json', frozen/TARGET,
                 frozen/'rtl/core/core_mem_chain.svh', frozen/'rtl/core/core.sv',
                 Path(pair.__file__), Path(pair.patch.__file__), pair_leaf/'closed.json',
                 pair_leaf/'core.sv', pair_proof/'closed.json'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    (root/'candidate/rtl/core/core.sv').write_text(changed_core)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p) != sha(root/'candidate'/p)] == TARGETS
    host = root/('tb_mc_pair_srt_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(before['host'], host)
    command = common.relocate(before['command'], parent, root, Path(before['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, host=str(host),
        definitions=definitions, parent_model=MODEL, parent=str(parent), changes=TARGETS,
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None,
        inherited_engine_operations=4544, inherited_engine_cycle_checks=162282,
        inherited_pair_response_clocks=77834,
        rationale='Measured SRT normalization 29.584 MHz and V-response 30.440 MHz paths; retain all MC/core fixes.'))
    print('MC-PAIR-SRT-PREPARED files=195 definitions=150 changes=2', flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins'])
    parent = Path(before['parent'])
    original = load(parent/'build-started.json')
    assert before['parent_model'] == MODEL and before['changes'] == TARGETS
    assert before['command'] == common.relocate(original['command'], parent, root,
                                               Path(original['host']), Path(before['host']))
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(before, compiler_started=True,
        preparation_sha256=sha(root/'prepared.json'), invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(before['command'], env={**os.environ, 'CCACHE_DISABLE': '1'},
                stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(before['pins']), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(result, flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    parser.add_argument('--out', type=Path, required=True)
    for key in ('parent', 'leaf', 'helper', 'pair-leaf', 'pair-proof'):
        parser.add_argument('--'+key, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert all(getattr(args, key) for key in ('parent', 'leaf', 'helper', 'pair_leaf', 'pair_proof'))
        prepare(args, root)
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
