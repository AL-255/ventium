#!/usr/bin/env python3
"""Freeze the sixteen-slot candidate, with exact full-PC compilation ancestry.

Only three parent payloads change: shim, build wrapper, and patched PL top.
One bridge file and VEN_DDR_POSTED are added. No acceptance is inherited from
the installed image or the still-running full-PC model. Does not run Vivado.
"""
import argparse
import json
from pathlib import Path
import subprocess

from freeze_rk_candidate import (FreezeError, absolute_path, checked_sha,
    directory, frozen_path, overlaps, publish_new, sha256, snapshot,
    unchanged, unique_json, write_new)

SHIM = 'ventium/ao486-sim/ven/ven_ao486_shim.sv'
WRAPPER = 'ventium/fpga/create_project_3mhz_wrapper.tcl'
BRIDGE = 'ventium/fpga/ven_ddram_axi_posted.sv'
TOP = 'flow/src/rk_ao486_system_pl.v'
SYSTEM = 'ventium/3rd-party/ao486_MiSTer/rtl/system.v'
ADDITIONS = ['SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM']


def require(ok, message):
    if not ok:
        raise FreezeError(message)


def freeze(args):
    parent, sim, repo, out = [absolute_path(x) for x in (args.parent, args.sim, args.repo, args.out)]
    identities = {p: directory(p) for p in (parent, sim, repo, out)}
    require(not any(overlaps(out, p) for p in (parent, sim, repo)) and not any(out.iterdir()),
            'output must be new/empty and outside input roots')
    observed = {}
    def read(path, digest=None, size=None):
        data = snapshot(path, digest, size)
        if path in observed:
            require(observed[path]['sha256'] == data['sha256'], 'input changed between reads')
        observed[path] = data
        return data
    def js(path, digest=None):
        return json.loads(read(path, digest)['data'], object_pairs_hook=unique_json)
    manifest = js(parent/'input-manifest.json', checked_sha(args.parent_sha256))
    prep = js(sim/'prepared.json', checked_sha(args.prepared_sha256))
    started = js(sim/'build1-speed-q16-started.json')
    closed = js(sim/'build1-speed-q16-closed.json', checked_sha(args.build_closed_sha256))
    require(manifest['schema'] == 1 and manifest['core_mhz'] == 40 and len(manifest['files']) == 180,
            'expected 180-payload forty-MHz bank64 parent')
    defs = manifest['hardware_defines']
    require(len(defs) == len(set(defs)) == 113 and defs[-3:] == ADDITIONS
            and manifest['simulator_defines'] == 110 and 'VEN_DDR_POSTED' not in defs,
            'unexpected parent define profile')
    require(read(parent/'defines.txt')['data'] == ('\n'.join(defs)+'\n').encode(), 'parent define drift')
    require(prep['baseline_manifest'] == args.parent_sha256 and prep['write_slots'] == 16
            and started['profile'] == 1 and started['write_slots'] == 16,
            'simulator is not this parent plus the sixteen-slot bridge')
    sim_defs = defs[:-3] + ['VEN_DDR_POSTED']
    require(prep['simulator_defines'] == sim_defs
            and read(sim/'defines.txt')['data'] == ('\n'.join(sim_defs)+'\n').encode(),
            'simulator define mismatch')
    require(closed['returncode'] == 0 and closed['inputs_unchanged'] is True, 'model build did not close cleanly')
    binary = sim/'obj1-speed-q16/ao486sim_board_posted'
    read(binary, checked_sha(closed['binary_sha256']))
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'],
            'actual simulator compile parameters differ')
    for name, digest in started['pins'].items():
        read(absolute_path(name), checked_sha(digest))

    payload = {}
    for record in manifest['files']:
        name = frozen_path(record['frozen'])
        require(name not in payload and name not in ('input-manifest.json','defines.txt'), 'duplicate/reserved payload')
        payload[name] = read(parent/name, checked_sha(record['sha256']), record['bytes'])
        # The private system top adds the transport ports; every other RTL and
        # explicit filelist must match the model actually compiled, not merely
        # an earlier manifest with a similar name or define count.
        if name.startswith('ventium/') and Path(name).suffix in ('.v','.sv','.vh','.svh','.f'):
            compiled = sim/'source'/name.removeprefix('ventium/')
            require(str(compiled) in started['pins'], 'source absent from actual model build: '+name)
            if name not in (SHIM, SYSTEM):
                require(started['pins'][str(compiled)] == record['sha256'], 'core/filelist drift: '+name)
    require(BRIDGE not in payload and all(n in payload for n in (SHIM, WRAPPER, TOP, SYSTEM)),
            'unexpected parent source layout')
    replacements = {SHIM: repo/SHIM.removeprefix('ventium/'), WRAPPER: repo/WRAPPER.removeprefix('ventium/')}
    for name in (SHIM, BRIDGE):
        live = repo/name.removeprefix('ventium/')
        data = read(live)
        compiled = sim/'source'/name.removeprefix('ventium/')
        require(data['sha256'] == started['pins'].get(str(compiled)), 'simulated shim/bridge drift: '+name)
    patch = repo/'fpga/patches/0010-posted-ddr-transport.patch'
    read(patch)
    for path in (Path(__file__).resolve(), repo/'fpga/freeze_rk_candidate.py', repo/'fpga/test_rk_wrapper.tcl'):
        read(path)
    for path in replacements.values(): read(path)
    for path, data in observed.items(): unchanged(path, data)

    records = []
    for name, old in payload.items():
        source = replacements.get(name, parent/name)
        data = observed[source]
        write_new(out/name, data['data'])
        records.append(dict(frozen=name, source=str(source), sha256=data['sha256'], bytes=data['bytes'],
            parent_sha256=old['sha256'], provenance='replacement' if name in replacements else 'parent_payload'))
    bridge = observed[repo/BRIDGE.removeprefix('ventium/')]
    write_new(out/BRIDGE, bridge['data'])
    records.append(dict(frozen=BRIDGE, source=str(repo/BRIDGE.removeprefix('ventium/')),
                        sha256=bridge['sha256'], bytes=bridge['bytes'], provenance='added_posted_bridge'))
    command = ['patch','--batch','--forward','--fuzz=0','-p3','-i',str(patch)]
    for dry in (True, False):
        p = subprocess.run(command+(['--dry-run'] if dry else []), cwd=out/'flow',
                           capture_output=True, text=True, timeout=10)
        write_new(out/('patch-check.log' if dry else 'patch-apply.log'), (p.stdout+p.stderr).encode())
        require(p.returncode == 0, 'exact board patch refused: '+p.stdout+p.stderr)
    patched = snapshot(out/TOP)
    top_record = next(r for r in records if r['frozen'] == TOP)
    top_record.update(sha256=patched['sha256'], bytes=patched['bytes'], provenance='exact_posted_patch',
                      patch_sha256=observed[patch]['sha256'])
    hardware_defs = sim_defs + ADDITIONS
    write_new(out/'defines.txt', ('\n'.join(hardware_defs)+'\n').encode())
    p = subprocess.run(['tclsh',str(repo/'fpga/test_rk_wrapper.tcl'),str(out/WRAPPER),
                        str(out/'flow'),str(out/'defines.txt'),str(out/'ventium'),str(out/'template')],
                       capture_output=True,text=True,timeout=10)
    require(p.returncode == 0 and 'POSTED-DDR-SOURCE-CONTRACT-OK' in p.stdout,
            'frozen Tcl source contract failed: '+p.stdout+p.stderr)
    write_new(out/'source-contract.log', (p.stdout+p.stderr).encode())
    for path, data in observed.items(): unchanged(path, data)
    require(all(directory(p)==identity for p,identity in identities.items()), 'directory identity changed')
    for r in records: snapshot(out/r['frozen'], r['sha256'], r['bytes'])
    result = dict(schema=1,qualification='UNQUALIFIED',core_mhz=40,simulator_defines=111,
        hardware_defines=hardware_defs,hardware_additions=ADDITIONS,files=records,
        parent_manifest_sha256=args.parent_sha256,simulator_sha256=closed['binary_sha256'],
        simulator_prepared_sha256=args.prepared_sha256,write_slots=16,
        changed_parent_payloads=[SHIM,WRAPPER,TOP],added_payloads=[BRIDGE],
        note='Source ancestry and static admission only. No suite, gameplay, synthesis or hardware acceptance inherited.')
    publish_new(out/'input-manifest.json', (json.dumps(result,indent=2)+'\n').encode())
    publish_new(out/'freeze-receipt.json', (json.dumps(dict(qualification='UNQUALIFIED',
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):d['sha256'] for p,d in observed.items()},source_contract_passed=True,
        payloads=len(records),hardware_defines=len(hardware_defs)),indent=2)+'\n').encode())
    return dict(output=str(out),qualification='UNQUALIFIED',payloads=len(records),hardware_defines=len(hardware_defs))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','parent-sha256','sim','prepared-sha256','build-closed-sha256','repo','out'):
        p.add_argument('--'+name,required=True)
    try:
        print(json.dumps(freeze(p.parse_args())))
    except (FreezeError,OSError,ValueError,KeyError,subprocess.SubprocessError) as e:
        raise SystemExit('posted candidate freeze refused: '+str(e)) from e


if __name__ == '__main__': main()
