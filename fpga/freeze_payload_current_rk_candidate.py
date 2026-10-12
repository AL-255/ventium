#!/usr/bin/env python3
"""Freeze the compiled combined timing core, with unchanged real 40 MHz clocks.

Source export only. No synthesis, routing, standard-suite or FPGA acceptance.
Use matched logic-only mapping for the next diagnostic frequency measurement.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import freeze_prime_noack_rk_candidate as base
from freeze_rk_candidate import (directory, frozen_path, overlaps, publish_new,
    sha256, snapshot, unchanged, write_new)

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_payload_current as recipe
import prepare_ic_fill_read_ack as ifill

PARENT = '485aec1484e25676312315347b406a80122f2e58a13065f8bdf39ac1f089a755'
MODEL = '0910a3be8bf6c3a5d293dfd8204e0be89e98bb1163a4f2eb6e73f547ddff133a'
CORE = 'fbe7b4e3b31c83396414de6802fe2e06dd4be0d4b039199dfc0f8e660154c8d6'
CHANGES = sorted(recipe.CURRENT)
require = base.require


def hardware_profile(parent, native):
    require(len(native) == len(set(native)) == 155 and recipe.payload.FLAG in native,
            'wrong native profile')
    base.profile(parent, [n for n in native if n != recipe.payload.FLAG])
    result = parent[:-3]+[recipe.payload.FLAG]+parent[-3:]
    require(len(result) == len(set(result)) == 157 and
            set(native) == set(result)-{'SYNTHESIS', 'VTM_NO_DPI'}, 'hardware feature drift')
    return result


def freeze(parent, sim, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(Path(os.environ['TMPDIR']).resolve() == scratch, 'wrong temporary directory')
    require(out.is_relative_to(scratch) and out != scratch and not out.exists(), 'output not fresh/external')
    require(not any(overlaps(out, p) for p in (parent, sim, REPO)), 'overlapping output')
    observed, aliases = {}, {}
    def read(path, digest=None, size=None):
        resolved = path.resolve(strict=True)
        aliases[path] = resolved
        return base.read_observed(observed, resolved, digest, size)
    def js(path, digest=None):
        return json.loads(read(path, digest)['data'])
    old = js(parent/'input-manifest.json', PARENT)
    require(old['variant'] == 'prime_noack_timing' and old['qualification'] == 'UNQUALIFIED'
            and old['core_mhz'] == 40 and old['write_slots'] == 16 and old['l2_sets'] == 1024
            and len(old['files']) == 190, 'wrong hardware predecessor')
    started, closed = js(sim/'build-started.json'), js(sim/'build-closed.json')
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
            and closed['binary_sha256'] == MODEL, 'native PC build not qualified for export')
    require(started['changes'] == CHANGES and started['added_defines'] == [recipe.payload.FLAG]
            and started['directed_model'] == CORE, 'unexpected native changes')
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', MODEL)
    for path, digest in started['pins'].items(): read(Path(path), digest)
    native = read(sim/'defines.txt')['data'].decode().splitlines()
    hw = hardware_profile(old['hardware_defines'], native)
    require(read(parent/'defines.txt')['data'] == ('\n'.join(old['hardware_defines'])+'\n').encode(), 'parent define drift')
    actual = [s[2:] for s in started['command'] if s.startswith('-D')]
    actual += [s[8:] for s in started['command'] if s.startswith('+define+')]
    require(len(actual) == len(native) and set(actual) == set(native), 'native command drift')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'], 'transport drift')
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(), started['command'])
    original = Path(started['proof'])/'core-r1/candidate'
    before = {n: read(parent/'ventium'/n)['data'].decode() for n in CHANGES}
    before['rtl/core/core.sv'] = ifill.transform(before['rtl/core/core.sv'])
    expected = recipe.transform(before, {n: read(original/n, recipe.payload.HASHES[n])['data'].decode() for n in CHANGES})
    payload, rows, changed, compiled = {}, [], [], 0
    for row in old['files']:
        name = frozen_path(row['frozen'])
        require(name not in payload, 'duplicate payload')
        prior = read(parent/name, row['sha256'], row['bytes'])
        data, source = prior['data'], parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'not a compiled native input: '+name)
            data = read(source, started['pins'][str(source)])['data']
            if name == base.SYSTEM: data = base.projection(prior['data'], data)
            else: compiled += 1
        if sha256(data) != prior['sha256']:
            relative = name.removeprefix('ventium/')
            require(relative in expected and data == expected[relative].encode(), 'unreviewed change: '+name)
            changed.append(name)
        payload[name] = dict(data=data)
        rows.append(dict(frozen=name, source=str(source), sha256=sha256(data), bytes=len(data), parent_sha256=prior['sha256']))
    require(sorted(changed) == ['ventium/'+n for n in CHANGES] and compiled == 170, 'incomplete source closure')
    require(base.source_closure(payload) == old['source_closure'] == dict(filelist_units=117, include_edges=49), 'filelist/include drift')
    checker = REPO/'fpga/test_payload_current_rk_wrapper.tcl'
    for p in (Path(__file__), Path(base.__file__), checker, REPO/'fpga/test_code_payload_rk_wrapper.tcl',
              Path(recipe.__file__), Path(ifill.__file__), Path(recipe.payload.__file__),
              Path(recipe.fetch.__file__), Path(recipe.overlap.__file__)):
        read(p)
    def stable():
        for p, info in observed.items(): unchanged(p, info)
        require(all(p.resolve(strict=True) == q for p,q in aliases.items()), 'source alias changed')
    stable()
    out.mkdir()
    identity = directory(out)
    for name, item in payload.items(): write_new(out/name, item['data'])
    write_new(out/'defines.txt', ('\n'.join(hw)+'\n').encode())
    command = ['tclsh', str(checker), str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
               str(out/'flow'), str(out/'defines.txt'), str(out/'ventium'), str(out/'template'), 'logic_only']
    done = subprocess.run(command, capture_output=True, text=True, timeout=15)
    write_new(out/'source-contract.log', (done.stdout+done.stderr).encode())
    require(done.returncode == 0 and 'exact157defs' in done.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in done.stdout,
            'Tcl source contract failed: '+done.stdout+done.stderr)
    stable()
    require(directory(out) == identity, 'output directory changed')
    for row in rows: snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    manifest = dict(schema=1, qualification='UNQUALIFIED', variant='payload_current_timing',
        core_mhz=40, write_slots=16, l2_sets=1024, hardware_defines=hw, simulator_defines=155,
        hardware_additions=['SYNTHESIS', 'VTM_NO_DPI'], parent_manifest_sha256=PARENT,
        simulator_sha256=MODEL, changed_parent_payloads=changed, added_payloads=[], changed_flow_payloads=[],
        source_closure=old['source_closure'], files=rows, source_contract_synthesis_profile='logic_only',
        canonical_gate_passed=started['canonical_gate_passed'], standard_suite=False, hardware_acceptance=False,
        note='Combined I-fill/bank-overlap/payload-kind cuts. Original 40 MHz clocks. Diagnostic mapping; no timing or FPGA pass inherited.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest, indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p): info['sha256'] for p,info in observed.items()},
        input_aliases={str(p): str(q) for p,q in aliases.items()}, payloads=len(rows))
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt, indent=2)+'\n').encode())
    return {k: receipt[k] for k in ('qualification', 'source_contract_passed', 'manifest_sha256', 'payloads')}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'sim', 'out'): ap.add_argument('--'+name, required=True, type=Path)
    args = ap.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True), args.sim.resolve(strict=True), args.out.resolve())))
