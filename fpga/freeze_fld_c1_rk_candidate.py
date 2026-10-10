#!/usr/bin/env python3
"""Export the tested shared-load C1 follow-up without changing the board profile.

Read-only with respect to all inputs. The output is a fresh source bundle, not
a qualified FPGA image. The host-only stdio fix is not an FPGA RTL change.
"""
import argparse
import json
from pathlib import Path
import subprocess

from freeze_rk_candidate import (FreezeError, absolute_path, checked_sha,
    directory, frozen_path, overlaps, publish_new, sha256, snapshot, unchanged,
    unique_json, write_new)
from freeze_performance_rk_candidate import source_closure
from freeze_code_payload_rk_candidate import projection, SCRIPT_ALIASES, SYSTEM, SUFFIXES
from test_ic_prefix_board_profile import check_native_command

SCRIPT_ALIASES = SCRIPT_ALIASES + ('ventium-fld-c1-core.Vr1KAdle/build.py',
                                 'ventium-fld-c1-soc.Ggbyni4b/build.py')

PARENT = '115db49eb65ece8653dd944d5ca559c347ca7fe0a58b06c23b55fb06041f6408'
MODEL = '455f65c2d69c7bc041c5e10236d1f277b35c74819297b8a3e0e85806a4023811'
TOP = 'fp_shared/ven_fp_top.sv'
TOP_SHA = '625fc83cd691c430ec167315def5060b761f5ac8565ee14b80072fb61cad5611'


def require(ok, message):
    if not ok:
        raise FreezeError(message)


def profile(parent, simulated):
    require(len(parent) == len(set(parent)) == 156, 'parent profile size/duplicates')
    require(len(simulated) == len(set(simulated)) == 154, 'native profile size/duplicates')
    require(set(parent) - set(simulated) == {'SYNTHESIS', 'VTM_NO_DPI'}
            and not set(simulated) - set(parent), 'native feature drift')
    require({'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
             'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT',
             'VEN_FP_SHARED', 'VEN_L1D_CODE_PAYLOAD_SELECT'} <= set(parent),
            'required UV/fast/shared-FP feature missing')
    return parent


def check_delta(name, old_digest, new_digest):
    if old_digest != new_digest:
        require(name == TOP and new_digest == TOP_SHA, 'unreviewed source delta: '+name)
        return True
    return False


def freeze(args):
    parent, sim, out = map(absolute_path, (args.parent, args.sim, args.out))
    repo = Path(__file__).resolve().parents[1]
    roots = {p: directory(p) for p in (parent, sim, out, repo)}
    require(not any(overlaps(out, p) for p in (parent, sim, repo)) and not any(out.iterdir()),
            'output must be fresh, empty and outside inputs')
    observed, aliases = {}, {}

    def read(p, digest=None, size=None):
        info = snapshot(p, digest, size)
        require(p not in observed or info == observed[p], 'input changed: '+str(p))
        observed[p] = info
        return info

    def js(p, digest=None):
        return json.loads(read(p, digest)['data'], object_pairs_hook=unique_json)

    old = js(parent/'input-manifest.json', PARENT)
    require(old['qualification'] == 'UNQUALIFIED' and old['variant'] == 'code_payload_fp_corrected'
            and old['core_mhz'] == 40 and old['write_slots'] == 16
            and old['l2_sets'] == 1024 and len(old['files']) == 190, 'wrong hardware parent')
    started = js(sim/'build-started.json', checked_sha(args.started_sha256))
    closed = js(sim/'build-closed.json', checked_sha(args.closed_sha256))
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
            and closed['binary_sha256'] == MODEL, 'native model not closed/pinned')
    require(started['changes'] == ['ao486-sim/ps/ps_shim.cpp', TOP]
            and started['added_defines'] == [], 'unexpected full-PC delta')
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', MODEL)
    hw = old['hardware_defines']
    require(read(parent/'defines.txt')['data'] == ('\n'.join(hw)+'\n').encode(),
            'hardware definition file drift')
    native = read(sim/'defines.txt')['data'].decode().splitlines()
    profile(hw, native)
    actual = [a[2:] for a in started['command'] if a.startswith('-D')]
    actual += [a[8:] for a in started['command'] if a.startswith('+define+')]
    require(len(actual) == len(native) and set(actual) == set(native), 'compiler feature drift')
    require('-GBOARD_POSTED=1' in started['command']
            and '-GBOARD_WRITE_SLOTS=16' in started['command'], 'transport drift')
    check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(),
                         started['command'])
    prefix = Path('/home/yukidama/external/tmp')
    admitted = {prefix/n: prefix.resolve(strict=True)/n for n in SCRIPT_ALIASES}
    for name, digest in started['pins'].items():
        p = absolute_path(name)
        resolved = p.resolve(strict=True)
        if p != resolved:
            require(p in admitted and admitted[p] == resolved, 'unexpected source alias: '+name)
            aliases[p] = resolved
        read(resolved, checked_sha(digest))
    payload, changed = {}, []
    compiled = 0
    for row in old['files']:
        name = frozen_path(row['frozen'])
        require(name not in payload, 'duplicate payload')
        before = read(parent/name, checked_sha(row['sha256']), row['bytes'])
        data, source = before['data'], parent/name
        provenance = 'historical_ancestry_only_not_acceptance'
        if name.startswith('ventium/') and Path(name).suffix in SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'not a native input: '+name)
            data = read(source, started['pins'][str(source)])['data']
            provenance = 'native_compiled_source'
            if name == SYSTEM:
                data = projection(before['data'], data)
                provenance = 'unchanged_hardware_top_proven_against_simulation'
            else:
                compiled += 1
        if check_delta(name.removeprefix('ventium/'), before['sha256'], sha256(data)):
            changed.append(name)
        payload[name] = dict(data=data, source=source, parent=before, provenance=provenance)
    require(changed == ['ventium/'+TOP] and compiled == 170, 'missing C1 change/source closure')
    closure = source_closure(payload)
    require(closure == old['source_closure'] == dict(filelist_units=117, include_edges=49),
            'filelist/include graph drift')
    checker = repo/'fpga/test_code_payload_rk_wrapper.tcl'
    for name in ('freeze_fld_c1_rk_candidate.py', 'freeze_rk_candidate.py',
                 'freeze_performance_rk_candidate.py', 'freeze_code_payload_rk_candidate.py',
                 'freeze_store_admit_rk_candidate.py', 'test_ic_prefix_board_profile.py',
                 'test_code_payload_rk_wrapper.tcl'):
        read(repo/'fpga'/name)

    def stable():
        for p, info in observed.items():
            unchanged(p, info)
        require(all(p.resolve(strict=True) == q for p, q in aliases.items()), 'source alias changed')
        require(all(directory(p) == identity for p, identity in roots.items()), 'root changed')

    stable()
    rows = []
    for name, item in payload.items():
        write_new(out/name, item['data'])
        rows.append(dict(frozen=name, source=str(item['source']), sha256=sha256(item['data']),
                         bytes=len(item['data']), parent_sha256=item['parent']['sha256'],
                         provenance=item['provenance']))
    write_new(out/'defines.txt', ('\n'.join(hw)+'\n').encode())
    result = subprocess.run(['tclsh', str(checker),
        str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'), str(out/'flow'),
        str(out/'defines.txt'), str(out/'ventium'), str(out/'template'), 'logic_only'],
        capture_output=True, text=True, timeout=15)
    write_new(out/'source-contract.log', (result.stdout+result.stderr).encode())
    require(result.returncode == 0 and 'exact156defs' in result.stdout
            and 'POSTED-DDR-SOURCE-CONTRACT-OK' in result.stdout, 'Tcl source contract failed')
    stable()
    for row in rows:
        snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    manifest = dict(schema=1, qualification='UNQUALIFIED', variant='fld_c1',
        core_mhz=40, write_slots=16, l2_sets=1024, hardware_defines=hw,
        simulator_defines=154, hardware_additions=['SYNTHESIS', 'VTM_NO_DPI'],
        parent_manifest_sha256=PARENT, simulator_sha256=MODEL,
        simulator_started_sha256=args.started_sha256, simulator_closed_sha256=args.closed_sha256,
        changed_parent_payloads=changed, added_payloads=[], changed_flow_payloads=[],
        source_closure=closure, files=rows, source_contract_synthesis_profile='logic_only',
        inherited_simulator_structural_warning_count=closed['structural_debt_count'],
        note='Source only. No suite/gameplay/timing/physical FPGA pass is inherited.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p): i['sha256'] for p, i in observed.items()},
        native_driver_aliases={str(p): str(q) for p, q in aliases.items()},
        payloads=len(rows), hardware_defines=len(hw), native_compiled_nonwrapper_payloads=compiled)
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {k: receipt[k] for k in ('qualification', 'source_contract_passed', 'manifest_sha256',
                                  'payloads', 'hardware_defines')}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'sim', 'out', 'started-sha256', 'closed-sha256'):
        ap.add_argument('--'+name, required=True)
    try:
        print(json.dumps(freeze(ap.parse_args())))
    except (FreezeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        raise SystemExit('shared-load C1 freeze refused: '+str(exc)) from exc


if __name__ == '__main__':
    main()
