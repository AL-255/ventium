"""Transfer the audited data-size cofactor into the unchanged UV-fast full PC.

One RTL delta; no mode, transport, memory geometry or verification waiver.
The canonical gate remains red, so this is an unqualified timing experiment.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'verif/segment_extent'))
import prepare_data_size as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = 'c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd'
CORE_MODEL = 'fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
AUDIT = '913c25bf68f8b2c65dd341c13b3e4356b44aa4ddcd7299e9f4a70f4243a79193'
CHANGES = [recipe.FILE]


def prepare(parent, core, proof, root):
    assert not root.exists() and sha(base.__file__) == BUILDER
    assert core == proof / 'core-r1' and sha(proof / 'audit.json') == AUDIT
    audit = load(proof / 'audit.json')
    assert audit['audit_passed'] and audit['changes'] == CHANGES
    assert (audit['functional_passes'], audit['functional_records'], audit['v_retirements']) == (108, 80800, 30134)
    assert audit['unmasked_functional_passes'] == 105 and audit['fetch_boundary_cases'] == 22
    assert audit['cycle_traces_unchanged'] == 20 and audit['canonical_gate_native_exit'] == 2
    assert not audit['canonical_gate_passed'] and not audit['hardware_acceptance']
    pins = dict(audit['artifacts'])
    before, built = load(core / 'build-started.json'), load(core / 'build-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert sha(core / 'obj/tb_ventium') == built['binary_sha256'] == CORE_MODEL
    pins.update(before['pins'])
    old, closed = load(parent / 'build-started.json'), load(parent / 'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert sha(parent / 'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == closed['binary_sha256'] == PARENT_MODEL
    source = parent / 'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == old['pins'][str(p)] for p in files)
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl', 'fp_shared')
              and (core / 'candidate' / p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [n for n in shared if sha(source / n) != sha(core / 'candidate' / n)] == CHANGES
    assert recipe.transform((source / recipe.FILE).read_text()) == (core / 'candidate' / recipe.FILE).read_text()
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source / 'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1 and stable(pins)
    root.mkdir()
    shutil.copytree(source, root / 'source')
    shutil.copyfile(core / 'candidate' / recipe.FILE, root / 'source' / recipe.FILE)
    assert all(sha(root / 'source' / n) == sha(core / 'candidate' / n) for n in shared)
    host = root / 'source/ao486-sim/ven' / ('sim_data_size_' + hashlib.sha256(str(root).encode()).hexdigest()[:12] + '.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/' + hosts[0].name) else s for s in command]
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2] == [str(REPO / 'tools/build_scope.sh'), '--'] and '600s' in command
    defs = [s[2:] for s in command if s.startswith('-D')] + [s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 156 and set(defs) == set((parent / 'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    assert "localparam bit AO486_LINE_REPLAY = 1'b0;" in (root / 'source/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    (root / 'defines.txt').write_text('\n'.join(sorted(defs)) + '\n')
    dependency = parent / 'obj1-speed-q16-parentpolicy' / (hosts[0].stem + '.d')
    for name in dependency.read_text().replace('\\\n', ' ').split()[1:]:
        path = Path(name)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for path in (*files, *(p for p in (root / 'source').rglob('*') if p.is_file()), Path(__file__),
                 Path(recipe.__file__), Path(base.__file__), Path(base.common.__file__),
                 root / 'defines.txt', proof / 'audit.json', parent / 'build-started.json',
                 parent / 'build-closed.json', parent / 'build.log', core / 'build-started.json',
                 core / 'build-closed.json', core / 'verify-closed.json', core / 'obj/tb_ventium'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    save(root / 'prepared.json', dict(command=command, pins=pins, changes=CHANGES, added_defines=[],
        parent=str(parent), directed_core=str(core), host=str(host), intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL, directed_model=CORE_MODEL, functional_corpus_passed=True,
        canonical_gate_passed=False, qualification='UNQUALIFIED'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    for name in ('parent', 'core', 'proof'): parser.add_argument('--' + name, type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5 * 1024**3 and sha(base.__file__) == BUILDER
    if args.action == 'prepare':
        assert args.parent and args.core and args.proof
        prepare(args.parent.resolve(strict=True), args.core.resolve(strict=True), args.proof.resolve(strict=True), root)
        print('One-file transfer prepared; canonical and hardware acceptance remain open.', flush=True)
        return 0
    return base.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
