#!/usr/bin/env python3
"""Build branch-ownership sharing in the unchanged posted-16 PC platform."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'proof', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--audit-sha256', required=True)
    args = parser.parse_args()
    parent, proof = args.parent.resolve(strict=True), args.proof.resolve(strict=True)
    root, core = args.out.resolve(), proof / 'core-r1'
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.is_relative_to(parent)
    assert Path(os.environ['TMPDIR']).resolve() == root
    assert shutil.disk_usage(scratch).free > 5 * 1024**3
    prior, closed = load(parent / 'build-started.json'), load(parent / 'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    assert sha(parent / 'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == closed['binary_sha256'] == 'c1161b0b665d6e3fafa03523df79a9a55f5ca0e042f197677096524c14fdd816'
    audit_path = proof / 'core-audit.json'
    assert re.fullmatch(r'[0-9a-f]{64}', args.audit_sha256)
    assert sha(audit_path) == args.audit_sha256
    audit = load(audit_path)
    assert audit['audit_complete'] and audit['directed_regressions_passed']
    assert audit['all_20_canonical_cycle_streams_identical'] and not audit['canonical_gate_passed']
    assert sum(r['fixtures'] for r in audit['counts'].values()) == 820
    assert sum(r['architectural_records'] for r in audit['counts'].values()) == 438312
    assert sha(core / 'obj/tb_ventium') == audit['model_sha256'] == '70900101369189169e472a78f7c4ca8ca34dbb99d6f45c0df5115d505b6a4a3e'
    fault_path = proof / 'faults-r1/closed.json'
    assert audit['focused_fault_cases'] == 16
    assert audit['same_input_canonical_cases'] == 108 and audit['same_input_canonical_records'] == 80800
    assert audit['pins'][str(fault_path)] == sha(fault_path)
    faults = load(fault_path)
    assert faults['passed'] and faults['pins_unchanged'] and not faults['errors']
    assert len(faults['measurements']) == 32
    pins = prior['pins'] | audit['pins'] | load(proof / 'faults-r1/started.json')['pins']
    pins.update({str(proof / 'faults-r1' / p): h for p, h in faults['artifacts'].items()})
    assert all(sha(p) == h for p, h in pins.items())
    changes, shared = ['rtl/core/core_mem_chain.svh'], []
    for group in ('rtl', 'fp_shared'):
        for p in (parent / 'source' / group).rglob('*'):
            rel = p.relative_to(parent / 'source')
            q = core / 'candidate' / rel
            if p.is_file() and q.is_file():
                shared.append(str(rel))
                if str(rel) not in changes:
                    assert sha(p) == sha(q), str(rel)
    assert len(shared) == 102
    assert sha(core / 'candidate' / changes[0]) == 'e044fcd954b5c2a0f0151e5e83198833faeffa875a776f17bb388fb2e21614cc'
    root.mkdir()
    shutil.copytree(parent / 'source', root / 'source')
    for rel in changes:
        shutil.copyfile(core / 'candidate' / rel, root / 'source' / rel)
    observed = sorted(str(p.relative_to(root / 'source')) for p in (root / 'source').rglob('*')
        if p.is_file() and sha(p) != sha(parent / 'source' / p.relative_to(root / 'source')))
    assert observed == changes
    assert all(sha(root / 'source' / rel) == sha(core / 'candidate' / rel) for rel in shared)
    hosts = [Path(s) for s in prior['command'] if s.startswith(str(parent / 'source/ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    oldhost = hosts[0]
    host = root / 'source/ao486-sim/ven' / ('sim_mc_branch_residency_' + root.parent.name.split('.')[-1].lower() + '.cpp')
    shutil.copyfile(oldhost, host)
    command = [s.replace(str(parent), str(root)) for s in prior['command']]
    command = [str(host) if s.endswith('/' + oldhost.name) else s for s in command]
    defs = lambda cmd: set(s[2:] for s in cmd if s.startswith('-D')) | set(s[8:] for s in cmd if s.startswith('+define+'))
    assert defs(command) == defs(prior['command']) and len(defs(command)) == 154
    with (root / 'defines.txt').open('x') as f:
        f.write('\n'.join(sorted(defs(command))) + '\n')
    def warnings(text):
        return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$', text, re.M))
    expected = warnings((parent / 'build.log').read_text())
    assert sum(expected.values()) == 98
    for p in (root / 'source').rglob('*'):
        if p.is_file():
            pins[str(p)] = sha(p)
    for p in (Path(__file__), root / 'defines.txt', parent / 'build-started.json', parent / 'build-closed.json',
              parent / 'build.log', audit_path, fault_path, core / 'build-closed.json'):
        pins[str(p)] = sha(p)
    def save(name, value):
        with (root / name).open('x') as f:
            json.dump(value, f, indent=2)
    save('build-started.json', dict(command=command, pins=pins, changes=changes, added_defines=[],
        intersecting_rtl_sources=shared, parent_model=closed['binary_sha256'], directed_model=audit['model_sha256'],
        canonical_gate_passed=False, invocation=os.environ.get('INVOCATION_ID')))
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False, errors=[], gameplay_ipc=None, standard_suite=False, qualification='UNQUALIFIED')
    begin = time.monotonic()
    try:
        with (root / 'build.log').open('x') as f:
            child = subprocess.run(command, cwd=root / 'source', env=env, stdout=f, stderr=subprocess.STDOUT, timeout=660)
        result['native_exit'] = child.returncode
        got = warnings((root / 'build.log').read_text())
        assert got == expected, (got - expected, expected - got)
        result.update(structural_warnings_unchanged=True, structural_debt_count=98)
        assert child.returncode == 0
        obj = root / 'obj1-speed-q16-parentpolicy'
        assert (obj / (host.stem + '.o')).is_file()
        headers = [Path(s) for s in (obj / (host.stem + '.d')).read_text().replace('\\\n', ' ').split() if Path(s).name == 'Vsystem___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj / headers[0]
        assert header.resolve() == (obj / 'Vsystem___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj / 'ao486sim_board_posted'), harness_header=str(header))
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(inputs_unchanged=all(sha(p) == h for p, h in pins.items()), seconds=time.monotonic() - begin)
        result['passed'] &= result['inputs_unchanged']
        save('build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

