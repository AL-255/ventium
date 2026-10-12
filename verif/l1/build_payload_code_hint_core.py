#!/usr/bin/env python3
"""Integrate both tested payload-kind recipes in a frozen private core.

Preparation may run while Vivado is active; compilation may not. Build requires
the exact current timing owner to close below 40 MHz and the real-cache gate to
pass. No architectural permission, cache geometry, or execution mode changes.
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

import prepare_payload_code_hint as recipe
import prepare_payload_fetch_kind as refine
import run_payload_code_hint_cache as cache_driver

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
import build_bus_cancel_core as common

MODEL = cache_driver.MODEL
TARGETS = sorted(recipe.HASHES)
sha, load, save, stable = common.sha, common.load, common.save, common.stable


def build_command(original, parent, root, oldhost, host):
    flags = [arg for arg in original if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 150 and recipe.FLAG not in definitions
    assert '--assert' in flags[0] and 'VL_J=32' in original
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI', 'VEN_RAW_V_READ_PRIME',
            'VEN_P54_DUAL_LOAD_PAIR', 'VEN_FP_PIPE', 'VEN_IC_BRAM'} <= set(definitions)
    assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_L1D_COMB_ACK', 'VEN_UOPCACHE'} & set(definitions)
    command = common.relocate(original, parent, root, oldhost, host)
    index = next(i for i, arg in enumerate(command) if arg.startswith('VL_EXTRA_DEFINES='))
    command[index] += ' +define+'+recipe.FLAG
    return command, definitions+[recipe.FLAG]


def cache_passed(result):
    assert result['passed'] and result['pins_unchanged'] and result['all_clock_interface_observations_identical']
    rows = result['variants']
    assert [(row['name'], row['build_exit'], row['positive_exit']) for row in rows] == [
        ('control', 0, 0), ('off', 0, 0), ('on', 0, 0)]
    assert rows[2]['negative_exit'] in (1, -6, 134)
    assert len({row['cycles_sha256'] for row in rows}) == 1
    for row in rows:
        assert all(any(marker in line for line in row['coverage']) for marker in cache_driver.MARKERS)


def prepare(args, root):
    assert not root.exists()
    parent, leaf, fetch, cache = [getattr(args, key).resolve(strict=True)
                                for key in ('parent', 'leaf', 'fetch', 'cache')]
    before, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == closed['binary_sha256'] == MODEL
    pins = dict(before['pins'])
    for folder, names, marker in (
        (leaf, ['positive', 'wrong_kind', 'early_wrong_owner', 'raw_hint_control'],
         'PAYLOAD-HINT-OK clocks=262144 reads=2048 '),
        (fetch, ['positive', 'lost_held_owner', 'wrong_resident_kind'],
         'PAYLOAD-FETCH-KIND-OK vectors=1048576 active=135192 ')):
        evidence, started = load(folder/'closed.json'), load(folder/'started.json')
        assert evidence['passed'] and evidence['pins_unchanged']
        assert [(row.get('name', row.get('label')), row['native_exit']) for row in evidence['rows']] == [
            (name, 0 if i == 0 else 1) for i, name in enumerate(names)]
        assert marker in evidence['rows'][0]['log']
        pins.update(started['pins'])
        for row, name in zip(evidence['rows'], names):
            path = folder/(name+'.log')
            assert path.read_text() == row['log']
            pins[str(path)] = sha(path)
            for suffix, key in (('.sv', 'source_sha256'), ('.vvp', 'binary_sha256')):
                path = folder/(name+suffix)
                assert sha(path) == row[key]
                pins[str(path)] = row[key]
        pins.update({str(folder/name): sha(folder/name) for name in ('started.json', 'closed.json')})
    cache_before = load(cache/'prepared.json')
    assert cache_before['parent_model'] == MODEL and cache_before['parent'] == str(parent)
    pins.update(cache_before['pins'])
    source = parent/'candidate'
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(path) == before['pins'][str(path)] for path in files)
    changed = recipe.transform({name: (source/name).read_text() for name in TARGETS})
    for name in TARGETS:
        assert changed[name] == (leaf/'candidate'/name).read_text()
    assert changed['rtl/mem/ven_l1d.sv'] == (cache/'candidate.sv').read_text()
    changed['rtl/core/core.sv'] = refine.transform(changed['rtl/core/core.sv'])
    for name in TARGETS:
        assert recipe.select_hint_branch(changed[name], False).split() == (source/name).read_text().split()
    for path in (Path(__file__), Path(recipe.__file__), Path(refine.__file__), Path(cache_driver.__file__),
                 Path(common.__file__), REPO/'verif/l1/build_mc_branch_residency_core.py',
                 REPO/'verif/issue_uv/prepare_bus_cancel_payload.py', cache/'prepared.json',
                 parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    for name, text in changed.items():
        (root/'candidate'/name).write_text(text)
    relative = [str(path.relative_to(source)) for path in files]
    assert [str(path.relative_to(root/'candidate')) for path in common.candidate_files(root/'candidate')] == relative
    assert [name for name in relative if sha(source/name) != sha(root/'candidate'/name)] == TARGETS
    # Unique across output directories, not just different from the parent.
    suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    host = root/('tb_payload_kind_'+suffix+'.cpp')
    shutil.copyfile(before['host'], host)
    command, definitions = build_command(before['command'], parent, root, Path(before['host']), host)
    assert definitions[:-1] == cache_before['definitions']
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/name): sha(root/'candidate'/name) for name in relative})
    save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), definitions=definitions,
        parent=str(parent), parent_model=MODEL, cache=str(cache), changes=TARGETS,
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None,
        standard_suite=False, hardware_acceptance=False))
    print('PAYLOAD-KIND-CORE-PREPARED files=195 definitions=151 changed=4; no compiler started', flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins'])
    cache = Path(before['cache'])
    gate = load(cache/'closed.json')
    cache_passed(gate)
    assert stable(load(cache/'started.json')['pins'])
    gate_artifacts = {}
    for row in gate['variants']:
        folder = cache/row['name']
        assert sha(folder/'obj/test') == row['binary_sha256']
        gate_artifacts[str(folder/'obj/test')] = row['binary_sha256']
        for label in ('positive', 'negative') if row['name'] == 'on' else ('positive',):
            assert sha(folder/(label+'.log')) == row[label+'_log_sha256']
            assert sha(folder/(label+'.cycles.txt.gz')) == row[label+'_observations_gz_sha256']
            gate_artifacts[str(folder/(label+'.log'))] = row[label+'_log_sha256']
            gate_artifacts[str(folder/(label+'.cycles.txt.gz'))] = row[label+'_observations_gz_sha256']
    timing = load(root.parent/'timing-queue/closed.json')
    assert timing['passed'] and timing['measurement_sequence_completed'] and timing['pins_unchanged']
    assert 0 < timing['unplaced_core_estimate_mhz'] < 40
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-payload-code-hint-after-timing-oct12.service',
        '-pInvocationID', '-pMainPID', '-pSubState', '-pExecMainStatus'], text=True).splitlines())
    assert owner == dict(InvocationID='4b6f6ea3cf7f4f9e980e704082bffcc5', MainPID='0',
                         SubState='exited', ExecMainStatus='0'), owner
    assert load(root.parent/'payload-cache-queue-r1/closed.json')['real_cache_gate_passed']
    original = load(Path(before['parent'])/'build-started.json')
    command, definitions = build_command(original['command'], Path(before['parent']), root,
                                        Path(original['host']), Path(before['host']))
    assert command == before['command'] and definitions == before['definitions']
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    before['pins'].update({str(path): sha(path) for path in (cache/'started.json', cache/'closed.json',
        root.parent/'timing-queue/closed.json', root.parent/'payload-cache-queue-r1/closed.json')})
    before['pins'].update(gate_artifacts)
    save(root/'build-started.json', dict(before, compiler_started=True, owner=owner,
        preparation_sha256=sha(root/'prepared.json'), invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False)
    began = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(name) for name in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
                   if Path(name).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(before['pins']), seconds=time.monotonic()-began)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json', result)
    print(result, flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    parser.add_argument('--out', required=True, type=Path)
    for name in ('parent', 'leaf', 'fetch', 'cache'):
        parser.add_argument('--'+name, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert all(getattr(args, name) for name in ('parent', 'leaf', 'fetch', 'cache'))
        prepare(args, root)
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
