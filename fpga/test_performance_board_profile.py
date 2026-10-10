#!/usr/bin/env python3
"""Independently audit a performance export and exercise real Tcl admission.

Usage: test_performance_board_profile.py PARENT_INPUTS SIM_BUILD EXPORT
No model, Vivado or board is run. Temporary negative profiles never change the
export, parent, or live simulator inputs.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if not __debug__:
        raise SystemExit('refusing disabled Python assertions')
    parent, sim, export = (Path(p).resolve(strict=True) for p in sys.argv[1:])
    repo = Path(__file__).resolve().parents[1]
    load = lambda p: json.loads(p.read_text())
    old = load(parent/'input-manifest.json')
    new = load(export/'input-manifest.json')
    receipt = load(export/'freeze-receipt.json')
    build = load(sim/'build-started.json')
    closed = load(sim/'build-closed.json')
    variant = new.get('variant', 'performance')
    assert variant in ('performance', 'sfetch16')
    extra_count = int(variant == 'sfetch16')
    flow_changes = set(new.get('changed_flow_payloads', []))
    assert flow_changes <= {'ventium/fpga/create_project_3mhz_wrapper.tcl'}
    if extra_count:
        assert flow_changes == {'ventium/fpga/create_project_3mhz_wrapper.tcl'}
    assert new['qualification'] == receipt['qualification'] == 'UNQUALIFIED'
    assert receipt['manifest_sha256'] == digest(export/'input-manifest.json')
    assert new['parent_manifest_sha256'] == digest(parent/'input-manifest.json')
    assert new['simulator_started_sha256'] == digest(sim/'build-started.json')
    assert new['simulator_closed_sha256'] == digest(sim/'build-closed.json')
    assert new['simulator_sha256'] == closed['binary_sha256'] == digest(
        sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    for path, pin in build['pins'].items(): assert digest(Path(path)) == pin, path
    for path, pin in receipt['input_pins'].items(): assert digest(Path(path)) == pin, path
    parent_rows = {r['frozen']: r for r in old['files']}
    rows = {r['frozen']: r for r in new['files']}
    assert len(rows) == len(new['files']) == 186 and len(parent_rows) == 181
    added = set(rows) - set(parent_rows)
    assert added == set(new['added_payloads']) and len(added) == 5
    changed, native = set(), 0
    for name, row in rows.items():
        actual = export/name
        assert actual.stat().st_size == row['bytes'] and digest(actual) == row['sha256'], name
        if name in parent_rows:
            prior = parent_rows[name]
            assert digest(parent/name) == prior['sha256'] == row['parent_sha256'], name
            if row['sha256'] != prior['sha256']: changed.add(name)
        else:
            assert row['parent_sha256'] is None
        if name in flow_changes:
            assert row['provenance'] == 'explicit_sha_pinned_flow_update'
            assert row['sha256'] == receipt['input_pins'][row['source']]
            assert digest(Path(row['source'])) == row['sha256']
        elif name == 'ventium/3rd-party/ao486_MiSTer/rtl/system.v':
            before = (parent/name).read_bytes()
            assert before.count(b'l2_cache cache') == 1
            assert actual.read_bytes() == before.replace(
                b'l2_cache cache', b'l2_cache #(.CACHE_SETS(1024)) cache')
            assert b'board_transport_' not in actual.read_bytes()
        elif name.startswith('ventium/') and actual.suffix in ('.v','.sv','.vh','.svh','.f'):
            source = sim/'source'/name.removeprefix('ventium/')
            assert digest(source) == row['sha256'] == build['pins'][str(source)], name
            native += 1
        else:
            assert row['sha256'] == parent_rows[name]['sha256'], name
    assert changed == set(new['changed_parent_payloads']) | flow_changes
    assert len(changed-flow_changes) == 11 + extra_count
    assert ('ventium/fp_shared/ven_fp_estdiv.sv' in changed) == bool(extra_count)
    defs = (export/'defines.txt').read_text().splitlines()
    simdefs = (sim/'defines.txt').read_text().splitlines()
    cmddefs = [a[2:] for a in build['command'] if a.startswith('-D')]
    cmddefs += [a[8:] for a in build['command'] if a.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 135 + extra_count and defs == new['hardware_defines']
    assert len(cmddefs) == len(set(cmddefs)) == 133 + extra_count and set(cmddefs) == set(simdefs)
    assert set(defs)-set(cmddefs) == {'SYNTHESIS','VTM_NO_DPI'}
    assert set(cmddefs)-set(defs) == set()
    assert defs[:111]+defs[132+extra_count:] == old['hardware_defines']
    if extra_count:
        assert defs[132] == 'VEN_SFETCH16_DEMAND'
    else:
        assert 'VEN_SFETCH16_DEMAND' not in defs
    assert new['core_mhz'] == 40 and new['write_slots'] == 16 and new['l2_sets'] == 1024
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix='ventium-performance-profile.', dir=scratch) as temp:
        profile = Path(temp)/'defines.txt'
        def check(values, good, frozen=export):
            nonlocal checks
            profile.write_text('\n'.join(values)+'\n')
            run = subprocess.run(['tclsh',str(repo/'fpga/test_rk_wrapper.tcl'),
                str(frozen/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
                str(frozen/'flow'),str(profile),str(frozen/'ventium'),str(frozen/'template'),
                new.get('source_contract_synthesis_profile', 'balanced') if frozen == export else 'balanced'],
                capture_output=True,text=True,timeout=15)
            out = run.stdout+run.stderr
            assert (run.returncode == 0) == good, out
            if good: assert f'exact{len(values)}defs' in out and 'POSTED-DDR-SOURCE-CONTRACT-OK' in out
            checks += 1
        check(defs,True)
        check(old['hardware_defines'],True,parent)
        # Complete extension is mandatory, even with the correct total count.
        for i in range(111,132):
            check(defs[:i]+defs[i+1:],False)
        for bad in ('VEN_CACHE_HALF','VEN_UOPCACHE','VEN_IC_NARROWB','VEN_DTLB_ASSOC_2WAY'):
            check(defs[:111]+[bad]+defs[112:],False)
        check(defs[:111]+[defs[112],defs[111]]+defs[113:],False)
        check(defs[:111]+[defs[112]]+defs[112:],False)
        check(defs+['VEN_EXTRA'],False)
        if extra_count:
            check(defs[:132]+defs[133:], True)
            for substitute in ('VEN_RET_SHORT_WINDOW','VEN_P54_WBUF_ADMIT_DISPATCH','VEN_UNREVIEWED'):
                check(defs[:132]+[substitute]+defs[133:],False)
            check(defs[:131]+[defs[132],defs[131]]+defs[133:],False)
    assert receipt['manifest_sha256'] == digest(export/'input-manifest.json')
    print(json.dumps(dict(passed=True,payloads=len(rows),native_source_payloads=native,
        changed_parent_payloads=len(changed),new_headers=len(added),tcl_checks=checks,
        variant=variant,changed_flow_payloads=len(flow_changes),
        qualification='UNQUALIFIED',note='Source/profile only; no hardware or suite acceptance.')))


if __name__ == '__main__': main()
