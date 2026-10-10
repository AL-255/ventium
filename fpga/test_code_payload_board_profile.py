#!/usr/bin/env python3
"""Independent code selector and FP correctness source/profile audit. Usage: PARENT SIM EXPORT [--publish]."""
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


def check_native_command(record, command):
    compiler = '/tools/verilator/v5.046/bin/verilator'
    assert command.count(compiler) == 1
    actual = [line for line in record.splitlines() if line.startswith('C ')]
    assert len(actual) == 1
    # verFiles serializes argv by joining spaces, including the single CFLAGS
    # string. Do not misclassify its two host -D macros as SystemVerilog defines.
    # Compare the ENTIRE actual native command, not just a filtered flag set.
    arguments = command[command.index(compiler)+1:]
    assert actual[0] == 'C "'+' '.join(arguments)+'"'


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
    assert old['variant'] == 'high_window_payload' and new['variant'] == 'code_payload_fp_corrected'
    assert sha(parent/'input-manifest.json') == '705bde4e59bc5dd5b5342ddb240a03c9cc24734abf33742736d05cf819249e81'
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
        relative=Path(path).relative_to('/home/yukidama/external/tmp')
        assert len(relative.parts)==2 and relative.name in (
            'build.py','run.py','run_matrix.py','run_prefix_matrix.py','run_boundaries.py')
        assert Path(path).resolve(strict=True) == Path(target) == sim.parent/relative
    # New build drivers and the repository's new invalidation matrix use
    # canonical paths. The previous boundary runner is ancestry, not a native
    # input to this core; the new boundary runner replaces it in this closure.
    from freeze_code_payload_rk_candidate import SCRIPT_ALIASES
    excluded = {'ventium-ic-buffered-soc.gsztNdDc/build.py',
                'ventium-ic-buffered-core.lC2f4l2d/run_matrix.py',
                'ventium-ic-prefix-soc.ApbJoeMH/build.py',
                'ventium-ic-prefix-core.v5Uu6dx1/run_prefix_matrix.py',
                'ventium-fp-load-payload-core.WsBqyEli/run_boundaries.py'}
    expected_aliases = {'/home/yukidama/external/tmp/'+s for s in SCRIPT_ALIASES if s not in excluded}
    assert len(expected_aliases)==22 and set(receipt['native_driver_aliases'])==expected_aliases
    oldrows = {r['frozen']:r for r in old['files']}
    rows = {r['frozen']:r for r in new['files']}
    assert len(rows) == len(new['files']) == 190 and len(oldrows) == 190
    assert set(rows) == set(oldrows)
    assert set(oldrows) <= set(rows) and new['added_payloads'] == []
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
    assert changes == set(new['changed_parent_payloads']) == {
        'ventium/rtl/fpu/fpu_srt_div.sv',
        'ventium/rtl/fpu/fpu_x87_pkg.sv',
        'ventium/fp_shared/ven_fp_alu.sv',
        'ventium/fp_shared/ven_fp_top.sv',
        'ventium/rtl/core/core.sv',
        'ventium/rtl/core/fpu_writeback.sv',
        'ventium/fp_shared/ven_fp_misc.sv',
        'ventium/rtl/mem/ven_l1d.sv'}
    assert new['changed_flow_payloads'] == []
    defs = (export/'defines.txt').read_text().splitlines()
    simdefs = (sim/'defines.txt').read_text().splitlines()
    cmddefs = [a[2:] for a in build['command'] if a.startswith('-D')]
    cmddefs += [a[8:] for a in build['command'] if a.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 156 and defs == new['hardware_defines']
    assert len(cmddefs) == len(set(cmddefs)) == 154 and set(cmddefs) == set(simdefs)
    # Audit the actual native compiler record independently of its launcher.
    record = sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat'
    check_native_command(record.read_text(), build['command'])
    assert '--assert' in build['command'] and '-GBOARD_POSTED=1' in build['command']
    assert '-GBOARD_WRITE_SLOTS=16' in build['command']
    assert set(defs)-set(cmddefs) == {'SYNTHESIS','VTM_NO_DPI'} and not set(cmddefs)-set(defs)
    assert defs == old['hardware_defines'][:-3] + ['VEN_L1D_CODE_PAYLOAD_SELECT'] + old['hardware_defines'][-3:]
    assert defs[143] == 'VEN_IC_RESIDENCY_SPAN' and defs[144] == 'VEN_IC_PREFIX_SPAN'
    assert new['core_mhz'] == 40 and new['write_slots'] == 16 and new['l2_sets'] == 1024
    assert new['source_closure'] == dict(filelist_units=117,include_edges=49)
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix='ventium-code-payload-profile.',dir=scratch) as temp:
        profile = Path(temp)/'defines.txt'
        def check(values, good):
            nonlocal checks
            profile.write_text('\n'.join(values)+'\n')
            run = subprocess.run(['tclsh',str(repo/'fpga/test_code_payload_rk_wrapper.tcl'),
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
        for i in range(133,153):
            # Removing the single new flag recovers the explicitly allowed parent;
            # any removal inside its existing bundles remains invalid.
            check(defs[:i]+defs[i+1:],i==152)
            check(defs[:i]+['VEN_UNREVIEWED']+defs[i+1:],False)
        for bad in ('VEN_CACHE_HALF','VEN_UOPCACHE','VEN_IC_NARROWB','VEN_DTLB_ASSOC_2WAY'):
            check(defs[:133]+[bad]+defs[134:],False)
        check(defs[:133]+[defs[134],defs[133]]+defs[135:],False)
        check(defs[:133]+[defs[134]]+defs[134:],False)
        check(defs[:144]+[defs[145],defs[144]]+defs[146:],False)
        check(defs[:144]+[defs[143]]+defs[145:],False)
        check(defs[:147]+[defs[148],defs[147]]+defs[149:],False)
        check(defs[:147]+[defs[148]]+defs[148:],False)
        check(defs[:148]+[defs[149],defs[148]]+defs[150:],False)
        check(defs[:149]+[defs[148]]+defs[150:],False)
        check(defs[:149]+[defs[150],defs[149]]+defs[151:],False)
        check(defs[:150]+[defs[149]]+defs[151:],False)
        check(defs[:150]+[defs[151],defs[150]]+defs[152:],False)
        check(defs[:151]+[defs[150]]+defs[152:],False)
        check(defs[:151]+[defs[152],defs[151]]+defs[153:],False)
        check(defs[:152]+[defs[151]]+defs[153:],False)
        check(defs+['VEN_EXTRA'],False)
    assert receipt['manifest_sha256'] == sha(export/'input-manifest.json')
    result = dict(passed=True,payloads=len(rows),native_source_payloads=native,
        changed_parent_payloads=len(changes),new_headers=0,tcl_checks=checks,
        manifest_sha256=receipt['manifest_sha256'], auditor_sha256=sha(Path(__file__)),
        qualification='UNQUALIFIED',note='Source/profile only; no lint, suite, timing or silicon pass.')
    if len(sys.argv) == 5:
        with (export/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps(result))


if __name__ == '__main__': main()
