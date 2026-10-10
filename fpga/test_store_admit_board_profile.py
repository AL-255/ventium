#!/usr/bin/env python3
"""Independent source/profile audit. Usage: PARENT SIM EXPORT [--publish]."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    assert __debug__
    assert len(sys.argv) in (4,5) and (len(sys.argv) == 4 or sys.argv[4] == '--publish')
    parent, sim, export = (Path(p).resolve(strict=True) for p in sys.argv[1:4])
    repo = Path(__file__).resolve().parents[1]
    load = lambda p: json.loads(p.read_text())
    old, new = load(parent/'input-manifest.json'), load(export/'input-manifest.json')
    receipt = load(export/'freeze-receipt.json')
    build, closed = load(sim/'build-started.json'), load(sim/'build-closed.json')
    assert new['qualification'] == receipt['qualification'] == 'UNQUALIFIED'
    assert receipt['manifest_sha256'] == sha(export/'input-manifest.json')
    assert new['parent_manifest_sha256'] == sha(parent/'input-manifest.json')
    assert new['simulator_started_sha256'] == sha(sim/'build-started.json')
    assert new['simulator_closed_sha256'] == sha(sim/'build-closed.json')
    assert new['simulator_sha256'] == closed['binary_sha256'] == sha(
        sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    for path,pin in build['pins'].items(): assert sha(Path(path)) == pin, path
    for path,pin in receipt['input_pins'].items(): assert sha(Path(path)) == pin, path
    for path,target in receipt['native_driver_aliases'].items():
        assert Path(path).resolve(strict=True) == Path(target) == sim/'build.py'
    oldrows = {r['frozen']:r for r in old['files']}
    rows = {r['frozen']:r for r in new['files']}
    assert len(rows) == len(new['files']) == 187 and len(oldrows) == 186
    assert set(rows)-set(oldrows) == set(new['added_payloads']) == {
        'ventium/rtl/core/core_raw_branch_mov.svh'}
    changes, native = set(), 0
    for name,row in rows.items():
        actual = export/name
        assert actual.stat().st_size == row['bytes'] and sha(actual) == row['sha256'], name
        if name in oldrows:
            prior = oldrows[name]
            assert sha(parent/name) == prior['sha256'] == row['parent_sha256'], name
            if row['sha256'] != prior['sha256']: changes.add(name)
        else:
            assert row['parent_sha256'] is None
        if name == 'ventium/3rd-party/ao486_MiSTer/rtl/system.v':
            assert actual.read_bytes() == (parent/name).read_bytes()
            assert b'board_transport_' not in actual.read_bytes()
            assert actual.read_bytes().count(b'l2_cache #(.CACHE_SETS(1024)) cache') == 1
        elif name.startswith('ventium/') and actual.suffix in ('.v','.sv','.vh','.svh','.f'):
            source = sim/'source'/name.removeprefix('ventium/')
            assert sha(source) == row['sha256'] == build['pins'][str(source)], name
            native += 1
        else:
            assert row['sha256'] == oldrows[name]['sha256'], name
    assert changes == set(new['changed_parent_payloads']) == {'ventium/'+s for s in (
        'rtl/core/core.sv','rtl/core/core_mem_chain.svh','rtl/core/core_prefix66_d1.svh',
        'rtl/core/core_prefix_ex_chain.svh','rtl/core/decode.sv',
        'rtl/mem/ven_axi_master.sv','rtl/mem/ven_l1d.sv')}
    assert new['changed_flow_payloads'] == []
    defs = (export/'defines.txt').read_text().splitlines()
    simdefs = (sim/'defines.txt').read_text().splitlines()
    cmddefs = [a[2:] for a in build['command'] if a.startswith('-D')]
    cmddefs += [a[8:] for a in build['command'] if a.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 146 and defs == new['hardware_defines']
    assert len(cmddefs) == len(set(cmddefs)) == 144 and set(cmddefs) == set(simdefs)
    assert set(defs)-set(cmddefs) == {'SYNTHESIS','VTM_NO_DPI'} and not set(cmddefs)-set(defs)
    assert defs[:133]+defs[143:] == old['hardware_defines']
    assert defs[133:143] == '''VEN_FAST_BYTE_MEM_CMP VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE
VEN_L1D_STORE_WINDOW_WARM VEN_L1D_WINDOW_WRITE_UPDATE VEN_P54_PREFIX66_SYSTEM
VEN_P54_PREFIX_EX_CHAIN VEN_P54_PREFIX_EX_SYSTEM VEN_P54_WBUF_ADMIT_DISPATCH
VEN_RAW_BRANCH_FALLTHROUGH_PRIME VEN_RET_SHORT_WINDOW'''.split()
    assert new['core_mhz'] == 40 and new['write_slots'] == 16 and new['l2_sets'] == 1024
    assert new['source_closure'] == dict(filelist_units=117,include_edges=46)
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix='ventium-store-admit-profile.',dir=scratch) as temp:
        profile = Path(temp)/'defines.txt'
        def check(values, good):
            nonlocal checks
            profile.write_text('\n'.join(values)+'\n')
            run = subprocess.run(['tclsh',str(repo/'fpga/test_store_admit_rk_wrapper.tcl'),
                str(export/'ventium/fpga/create_project_3mhz_wrapper.tcl'),str(export/'flow'),
                str(profile),str(export/'ventium'),str(export/'template'),'logic_only'],
                capture_output=True,text=True,timeout=15)
            output = run.stdout+run.stderr
            assert (run.returncode == 0) == good, output
            if good:
                assert f'exact{len(values)}defs' in output and 'POSTED-DDR-SOURCE-CONTRACT-OK' in output
            checks += 1
        check(defs,True)
        check(old['hardware_defines'],True)
        for i in range(133,143):
            check(defs[:i]+defs[i+1:],False)
            check(defs[:i]+['VEN_UNREVIEWED']+defs[i+1:],False)
        for bad in ('VEN_CACHE_HALF','VEN_UOPCACHE','VEN_IC_NARROWB','VEN_DTLB_ASSOC_2WAY'):
            check(defs[:133]+[bad]+defs[134:],False)
        check(defs[:133]+[defs[134],defs[133]]+defs[135:],False)
        check(defs[:133]+[defs[134]]+defs[134:],False)
        check(defs+['VEN_EXTRA'],False)
    assert receipt['manifest_sha256'] == sha(export/'input-manifest.json')
    result = dict(passed=True,payloads=len(rows),native_source_payloads=native,
        changed_parent_payloads=len(changes),new_headers=1,tcl_checks=checks,
        manifest_sha256=receipt['manifest_sha256'], auditor_sha256=sha(Path(__file__)),
        qualification='UNQUALIFIED',note='Source/profile only; no lint, suite, timing or silicon pass.')
    if len(sys.argv) == 5:
        with (export/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps(result))


if __name__ == '__main__': main()
