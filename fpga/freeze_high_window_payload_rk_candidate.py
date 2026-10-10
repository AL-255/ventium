#!/usr/bin/env python3
"""Freeze the tested saved-window upper-word payload derivative; no Vivado or deployment.

All processor sources come from the actual native compilation, not the dirty
checkout. The historical sfetch16 hardware wrapper/clocking stays unchanged.
This is source closure only; no previous suite or hardware pass is inherited.
"""
import argparse
import json
from pathlib import Path
import subprocess

from freeze_rk_candidate import (FreezeError, absolute_path, checked_sha,
    directory, frozen_path, overlaps, publish_new, sha256, snapshot, unchanged,
    unique_json, write_new)
from freeze_performance_rk_candidate import hardware_system, source_closure
from freeze_store_admit_rk_candidate import EXTRA as PARENT_EXTRA

PARENT = '3ab7194b6004cea114ad709014d7d171587bfe8bc303fbc58469d3d8801fa5de'
CHANGES = {
    'rtl/mem/ven_l1d.sv': 'd78345f1fc81235d5c4881d2ad645eda89ee5da808f2a4131d5bbdda3e178436',
}
SYSTEM = 'ventium/3rd-party/ao486_MiSTer/rtl/system.v'
SUFFIXES = ('.v', '.sv', '.vh', '.svh', '.f')
# Exact historical script aliases carried by this native model's source/proof
# closure. No RTL, memory image, arbitrary symlink or unreviewed alias is allowed.
SCRIPT_ALIASES = tuple(name+'/build.py' for name in (
    'ventium-agi-prime.Fn1fJVfX','ventium-wbuf-admit.D1XyDU1j',
    'ventium-current-coremark-host-r2.3ixLJTn1','ventium-estdiv-core.WTmkYNQl',
    'ventium-sfetch16-core.Jk3rQBYO','ventium-prefix66-system.Gv8TOU2v',
    'ventium-prefix66-ret-core.QiUDj04M','ventium-raw-branch-core.4jVQ52FQ',
    'ventium-independent-window-core.1I9OR3Ub','ventium-prefix-ex-system-core.1Nzzc4xS',
    'ventium-prefix-ex-irq-core.gnc3N0NS','ventium-window-update-core-r2.ZvXU1hOO',
    'ventium-byte-cmp-core.0JAvTgvU','ventium-store-warm-core.QQBHmz8z',
    'ventium-ic-buffered-core.lC2f4l2d','ventium-ic-buffered-soc.gsztNdDc')) + (
    'ventium-ic-buffered-core.lC2f4l2d/run_matrix.py',
    'ventium-ic-prefix-core.v5Uu6dx1/build.py',
    'ventium-ic-prefix-soc.ApbJoeMH/build.py',
    'ventium-ic-prefix-core.v5Uu6dx1/run_prefix_matrix.py',)
SCRIPT_ALIASES += ('ventium-fp-load-payload-core.WsBqyEli/run_boundaries.py',
                   'ventium-fp-high-payload-core.WO4FljgA/run_boundaries.py',)

SCRIPT_ALIASES += ('ventium-response-payload-core.pndCkpV5/build.py',
                   'ventium-response-payload-soc.ZMhPPhmY/build.py',)


def require(ok, why):
    if not ok:
        raise FreezeError(why)


def profile(parent, simulated):
    require(len(parent) == len(set(parent)) == 154
            and parent[132] == 'VEN_SFETCH16_DEMAND'
            and parent[133:143] == list(PARENT_EXTRA)
            and parent[143:145] == ['VEN_IC_RESIDENCY_SPAN','VEN_IC_PREFIX_SPAN']
            and parent[145:] == ['VEN_CACHEINV_LOCAL','VEN_FP_PIPE_PAYLOAD_SELECT',
                'VEN_SRT_PAYLOAD_SELECT','VEN_FP_LOAD_PAYLOAD_SELECT','VEN_FP_LOAD64_PAYLOAD_SELECT',
                'VEN_L1D_RESPONSE_PAYLOAD_SELECT','SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM'],
            'wrong current-response payload parent profile')
    require(len(simulated) == len(set(simulated)) == 153, 'wrong native profile size/duplicates')
    out = parent[:-3] + ['VEN_L1D_HIGH_PAYLOAD_SELECT'] + parent[-3:]
    require(set(simulated) == set(out) - {'SYNTHESIS','VTM_NO_DPI'}, 'native feature drift')
    return out


def projection(parent, simulated):
    anchor = b'l2_cache #(.CACHE_SETS(1024)) cache'
    require(parent.count(anchor) == 1, 'hardware geometry drift')
    rebuilt = hardware_system(parent.replace(anchor, b'l2_cache cache'), simulated)
    require(rebuilt == parent, 'hardware top would change')
    return parent


def freeze(args):
    model = checked_sha(args.model_sha256)
    parent, sim, out = map(absolute_path, (args.parent, args.sim, args.out))
    repo = Path(__file__).resolve().parents[1]
    identities = {p: directory(p) for p in (parent, sim, out, repo)}
    require(not any(overlaps(out, p) for p in (parent,sim,repo)) and not any(out.iterdir()),
            'output must be fresh, empty and outside inputs')
    observed, aliases = {}, {}
    def read(p, digest=None, size=None):
        info = snapshot(p, digest, size)
        if p in observed:
            require(info == observed[p], 'input changed between reads: '+str(p))
        observed[p] = info
        return info
    def js(p, digest=None):
        return json.loads(read(p,digest)['data'], object_pairs_hook=unique_json)
    old = js(parent/'input-manifest.json', PARENT)
    require(old['variant'] == 'response_payload' and old['qualification'] == 'UNQUALIFIED'
            and old['core_mhz'] == 40 and old['write_slots'] == 16
            and old['l2_sets'] == 1024 and len(old['files']) == 190, 'wrong hardware parent')
    started = js(sim/'build-started.json', checked_sha(args.started_sha256))
    closed = js(sim/'build-closed.json', checked_sha(args.closed_sha256))
    require(closed['passed'] is True and closed['native_exit'] == 0
            and closed['inputs_unchanged'] is True and closed['binary_sha256'] == model,
            'native build not closed/pinned')
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', model)
    parent_defs = old['hardware_defines']
    require(read(parent/'defines.txt')['data'] == ('\n'.join(parent_defs)+'\n').encode(),
            'parent definitions changed')
    sim_defs = read(sim/'defines.txt')['data'].decode().splitlines()
    hw_defs = profile(parent_defs, sim_defs)
    actual = [a[2:] for a in started['command'] if a.startswith('-D')]
    actual += [a[8:] for a in started['command'] if a.startswith('+define+')]
    require(len(actual) == len(sim_defs) and set(actual) == set(sim_defs), 'compiler define drift')
    from test_ic_prefix_board_profile import check_native_command
    check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(), started['command'])
    require('-GBOARD_POSTED=1' in started['command'] and
            '-GBOARD_WRITE_SLOTS=16' in started['command'], 'transport drift')
    for p,h in started['pins'].items():
        pinned = absolute_path(p)
        resolved = pinned.resolve(strict=True)
        if resolved != pinned:
            prefix = Path('/home/yukidama/external/tmp')
            canonical = prefix.resolve(strict=True)
            admitted = {prefix/name:canonical/name for name in SCRIPT_ALIASES}
            require(pinned in admitted and resolved == admitted[pinned]
                    and resolved.is_relative_to(prefix.resolve(strict=True)),
                    'unexpected native pin alias: '+p)
            aliases[pinned] = resolved
        read(resolved, checked_sha(h))
    payload, changed = {}, set()
    for row in old['files']:
        name = frozen_path(row['frozen'])
        require(name not in payload, 'duplicate parent payload')
        before = read(parent/name, checked_sha(row['sha256']), row['bytes'])
        data, source = before['data'], parent/name
        provenance = 'historical_ancestry_only_not_acceptance'
        if name.startswith('ventium/') and Path(name).suffix in SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'not a compiled input: '+name)
            data = read(source, started['pins'][str(source)])['data']
            provenance = 'native_compiled_source'
            if name == SYSTEM:
                data = projection(before['data'], data)
                provenance = 'unchanged_hardware_top_proven_against_simulation'
        if sha256(data) != before['sha256']:
            relative = name.removeprefix('ventium/')
            require(relative in CHANGES and sha256(data) == CHANGES[relative],
                    'unreviewed source delta: '+name)
            changed.add(relative)
        payload[name] = dict(data=data, source=source, parent=before, provenance=provenance)
    require(changed == set(CHANGES), 'missing reviewed source deltas')
    closure = source_closure(payload)
    require(old['source_closure'] == dict(filelist_units=117,include_edges=49)
            and closure == dict(filelist_units=117,include_edges=49), 'filelist/include graph drift')
    checker = repo/'fpga/test_high_window_payload_rk_wrapper.tcl'
    for p in (Path(__file__).resolve(), checker, repo/'fpga/freeze_rk_candidate.py',
              repo/'fpga/freeze_performance_rk_candidate.py',
              repo/'fpga/freeze_store_admit_rk_candidate.py',
              repo/'fpga/test_ic_prefix_board_profile.py'): read(p)
    for p,info in observed.items(): unchanged(p, info)
    require(all(p.resolve(strict=True) == target for p,target in aliases.items()),
            'native build-driver alias changed')
    rows = []
    for name,item in payload.items():
        write_new(out/name, item['data'])
        rows.append(dict(frozen=name, source=str(item['source']),
            sha256=sha256(item['data']), bytes=len(item['data']),
            parent_sha256=item['parent']['sha256'] if item['parent'] else None,
            provenance=item['provenance']))
    write_new(out/'defines.txt', ('\n'.join(hw_defs)+'\n').encode())
    result = subprocess.run(['tclsh', str(checker),
        str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),str(out/'flow'),
        str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),'logic_only'],
        capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log', (result.stdout+result.stderr).encode())
    require(result.returncode == 0 and 'exact155defs' in result.stdout
            and 'POSTED-DDR-SOURCE-CONTRACT-OK' in result.stdout, 'Tcl source contract failed')
    for p,info in observed.items(): unchanged(p, info)
    require(all(p.resolve(strict=True) == target for p,target in aliases.items()),
            'native build-driver alias changed')
    for p,identity in identities.items(): require(directory(p) == identity, 'root changed')
    for row in rows: snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    manifest = dict(schema=1, qualification='UNQUALIFIED', variant='high_window_payload',
        core_mhz=40, write_slots=16, l2_sets=1024, hardware_defines=hw_defs,
        simulator_defines=len(sim_defs), hardware_additions=['SYNTHESIS','VTM_NO_DPI'],
        parent_manifest_sha256=PARENT, simulator_sha256=model,
        simulator_started_sha256=args.started_sha256, simulator_closed_sha256=args.closed_sha256,
        changed_parent_payloads=['ventium/'+s for s in sorted(changed)],
        added_payloads=[], changed_flow_payloads=[], source_closure=closure, files=rows,
        source_contract_synthesis_profile='logic_only',
        inherited_simulator_structural_warning_count=closed['structural_debt_count'],
        note='No lint/suite/gameplay/timing/FPGA acceptance is inherited or granted.')
    publish_new(out/'input-manifest.json', (json.dumps(manifest,indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED',source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):i['sha256'] for p,i in observed.items()},
        native_driver_aliases={str(p):str(target) for p,target in aliases.items()},
        payloads=len(rows), hardware_defines=len(hw_defs),
        note='Source only. No Vivado or board operation; historical evidence is ancestry only.')
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','manifest_sha256',
                                  'payloads','hardware_defines')}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out','started-sha256','closed-sha256','model-sha256'):
        ap.add_argument('--'+name, required=True)
    try:
        print(json.dumps(freeze(ap.parse_args())))
    except (FreezeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        raise SystemExit('high-window freeze refused: '+str(exc)) from exc


if __name__ == '__main__': main()
