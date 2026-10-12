#!/usr/bin/env python3
"""Export the compiled two-cut candidate, preserving the measured RK flow.

This creates fresh unqualified inputs only. It never starts Vivado or deploys.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from freeze_rk_candidate import (FreezeError, directory, frozen_path, overlaps,
    publish_new, sha256, snapshot, unchanged, write_new)
from freeze_performance_rk_candidate import source_closure
from freeze_code_payload_rk_candidate import projection, SYSTEM, SUFFIXES
from freeze_bus_cancel_rk_candidate import profile, read_observed
from test_ic_prefix_board_profile import check_native_command

REPO = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(REPO/'verif/l1'), str(REPO/'verif/srt')]
import prepare_pair_response_read_commit as pair
import prepare_input_norm_tree as srt

PARENT = '8bf3e5b5444b681ed8fa38d936bdb948fa028d6f37c63b47eca6c6e6060be9da'
CORE_MODEL = 'eefa9d57c41c5eb5154d0319fb2e82240f90469b7ce119ae0abe36d6aada9702'
CHANGES = {
    'ventium/rtl/core/core.sv': '8d0c3c35eca0c3ea97981d3f33178ef0c656a2eb90f27faea97fe998ab5e24a0',
    'ventium/rtl/fpu/fpu_srt_div.sv': 'b53e94fbcb0f02cf1a90a110cca9144b2266808d9a8480c509e7364d50f69661',
}


def require(condition, message):
    if not condition:
        raise FreezeError(message)


def expected_payloads(core, engine):
    values = dict(zip(CHANGES, (pair.transform(core).encode(), srt.transform(engine).encode())))
    require(all(sha256(data) == CHANGES[name] for name, data in values.items()),
            'unexpected recipe result')
    return values


def freeze(parent, sim, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(Path(os.environ['TMPDIR']).resolve() == scratch, 'wrong temporary directory')
    require(out.is_relative_to(scratch) and out != scratch and not out.exists(), 'output not fresh/external')
    require(not any(overlaps(out, path) for path in (parent, sim, REPO)), 'overlapping output')
    observed, aliases = {}, {}

    def read(path, digest=None, size=None):
        resolved = path.resolve(strict=True)
        aliases[path] = resolved
        return read_observed(observed, resolved, digest, size)

    def js(path, digest=None):
        return json.loads(read(path, digest)['data'])

    old = js(parent/'input-manifest.json', PARENT)
    require(old['variant'] == 'mc_read_commit' and old['qualification'] == 'UNQUALIFIED'
            and old['core_mhz'] == 40 and old['write_slots'] == 16 and old['l2_sets'] == 1024,
            'wrong hardware predecessor')
    require(len(old['files']) == 190, 'parent payload count changed')
    started, closed = js(sim/'build-started.json'), js(sim/'build-closed.json')
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged'], 'PC build not closed')
    require(started['changes'] == [p.removeprefix('ventium/') for p in CHANGES]
            and not started['added_defines'], 'unexpected native changes')
    require(started['directed_model'] == CORE_MODEL, 'wrong directed model')
    model = closed['binary_sha256']
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', model)
    for raw, digest in started['pins'].items():
        read(Path(raw), digest)
    hw = old['hardware_defines']
    native = read(sim/'defines.txt')['data'].decode().splitlines()
    require(read(parent/'defines.txt')['data'] == ('\n'.join(hw)+'\n').encode(), 'hardware define drift')
    profile(hw, native)
    actual = [s[2:] for s in started['command'] if s.startswith('-D')]
    actual += [s[8:] for s in started['command'] if s.startswith('+define+')]
    require(len(actual) == len(native) and set(actual) == set(native), 'native define drift')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'],
            'transport drift')
    check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(), started['command'])
    payload, rows, changed, compiled = {}, [], [], 0
    for row in old['files']:
        name = frozen_path(row['frozen'])
        require(name not in payload, 'duplicate payload')
        before = read(parent/name, row['sha256'], row['bytes'])
        data, source = before['data'], parent/name
        if name.startswith('ventium/') and Path(name).suffix in SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'not a compiled native input: '+name)
            data = read(source, started['pins'][str(source)])['data']
            if name == SYSTEM:
                data = projection(before['data'], data)
            else:
                compiled += 1
        if sha256(data) != before['sha256']:
            require(name in CHANGES and sha256(data) == CHANGES[name], 'unreviewed source change: '+name)
            changed.append(name)
        payload[name] = dict(data=data)
        rows.append(dict(frozen=name, source=str(source), sha256=sha256(data),
                         bytes=len(data), parent_sha256=before['sha256']))
    require(changed == list(CHANGES) and compiled == 170, 'incomplete native source closure')
    expected = expected_payloads(read(parent/'ventium/rtl/core/core.sv')['data'].decode(),
                                 read(parent/'ventium/rtl/fpu/fpu_srt_div.sv')['data'].decode())
    require(all(payload[name]['data'] == data for name, data in expected.items()), 'recipe differs')
    require(source_closure(payload) == old['source_closure'] == dict(filelist_units=117, include_edges=49),
            'filelist/include drift')
    checker = REPO/'fpga/test_code_payload_rk_wrapper.tcl'
    for path in (Path(__file__), checker, REPO/'fpga/freeze_rk_candidate.py',
                 REPO/'fpga/freeze_bus_cancel_rk_candidate.py', REPO/'fpga/freeze_performance_rk_candidate.py',
                 REPO/'fpga/freeze_code_payload_rk_candidate.py', REPO/'fpga/freeze_prefix_regonly_rk_candidate.py',
                 Path(pair.__file__), Path(srt.__file__)):
        read(path)

    def stable():
        for path, info in observed.items():
            unchanged(path, info)
        require(all(p.resolve(strict=True) == r for p, r in aliases.items()), 'source alias changed')

    stable()
    out.mkdir()
    identity = directory(out)
    for name, item in payload.items():
        write_new(out/name, item['data'])
    write_new(out/'defines.txt', ('\n'.join(hw)+'\n').encode())
    command = ['tclsh', str(checker), str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
               str(out/'flow'), str(out/'defines.txt'), str(out/'ventium'), str(out/'template'), 'logic_only']
    done = subprocess.run(command, capture_output=True, text=True, timeout=15)
    write_new(out/'source-contract.log', (done.stdout+done.stderr).encode())
    require(done.returncode == 0 and 'exact156defs' in done.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in done.stdout,
            'source contract failed')
    stable()
    require(directory(out) == identity, 'output directory changed')
    for row in rows:
        snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    manifest = dict(schema=1, qualification='UNQUALIFIED', variant='mc_pair_srt_timing',
        core_mhz=40, write_slots=16, l2_sets=1024, hardware_defines=hw, simulator_defines=154,
        hardware_additions=['SYNTHESIS', 'VTM_NO_DPI'], parent_manifest_sha256=PARENT,
        simulator_sha256=model, changed_parent_payloads=changed, added_payloads=[], changed_flow_payloads=[],
        source_closure=old['source_closure'], files=rows, source_contract_synthesis_profile='logic_only',
        canonical_gate_passed=started['canonical_gate_passed'], standard_suite=False, hardware_acceptance=False,
        note='Combined response-read and SRT normalization timing diagnostic; no inherited acceptance.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p): info['sha256'] for p, info in observed.items()},
        input_aliases={str(p): str(r) for p, r in aliases.items()}, payloads=len(rows))
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {key: receipt[key] for key in ('qualification', 'source_contract_passed', 'manifest_sha256', 'payloads')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'sim', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True), args.sim.resolve(strict=True), args.out.resolve())))
