"""Transfer the qualified environment/FRNDINT repair into the full PC.

Keep the existing segment, LMSW and obsolete-x87 repairs, all shared sources,
UV-fast/full-P5 profile, posted transport and bounded native builder.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_payload_current_soc as base
import fp_repair_transfer as recipe

REPO = Path(__file__).resolve().parents[1]
sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = 'f0b7197c7b1becc3043f18ffe650c4956152ae8a20fc7397f9213f55ebdd5d98'
CORE_MODEL = '2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63'
BOARD_MODEL = '889bae534d468ae9c6ce14aa405e411b86f50a8f3bfbf7436f3bedbc990bb00a'
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
AUDIT = '3f46ab49fc09803302e6281d487eebcd4274e4f5a392ba7b51ef13c0a581644f'
CHANGES = sorted(recipe.PARENTS)


def prepare(parent, core, proof, root):
    assert not root.exists() and sha(base.__file__) == BUILDER
    assert sha(proof / 'audit.json') == AUDIT
    audit = load(proof / 'audit.json')
    assert audit['audit_passed'] and audit['functional_passes'] == 108
    assert (audit['functional_records'], audit['functional_v_retirements']) == (80800, 30134)
    assert audit['unmasked_functional_passes'] == 105 and audit['cycle_runs'] == 88
    assert not audit['canonical_gate_passed'] and not audit['hardware_acceptance']
    pins = dict(audit['artifacts'])
    pins.update(load(proof / 'board-func-r1/started.json')['pins'])
    checked_core = proof / 'board-core-r1'
    checked = load(checked_core / 'build-closed.json')
    assert checked['passed'] and checked['native_exit'] == 0 and checked['pins_unchanged']
    assert checked['binary_sha256'] == sha(checked_core / 'obj/tb_ventium') == BOARD_MODEL
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
    assert len(shared) == 102 and [n for n in shared if sha(source / n) != sha(core / 'candidate' / n)] == CHANGES
    assert all(sha(core / 'candidate' / n) == sha(checked_core / 'candidate' / n) for n in shared)
    for name in CHANGES:
        assert recipe.transform((source / name).read_text(), name) == (core / 'candidate' / name).read_text()
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source / 'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1 and stable(pins)
    root.mkdir()
    shutil.copytree(source, root / 'source')
    for name in CHANGES:
        shutil.copyfile(core / 'candidate' / name, root / 'source' / name)
    assert all(sha(root / 'source' / n) == sha(core / 'candidate' / n) for n in shared)
    host = root / 'source/ao486-sim/ven' / ('sim_fp_repair_' + hashlib.sha256(str(root).encode()).hexdigest()[:12] + '.cpp')
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
                 Path(recipe.__file__), Path(recipe.restore.__file__), Path(recipe.store.__file__),
                 Path(recipe.rounding.__file__), Path(base.__file__), Path(base.common.__file__),
                 root / 'defines.txt', proof / 'audit.json', checked_core / 'build-closed.json',
                 parent / 'build-started.json', parent / 'build-closed.json', parent / 'build.log',
                 core / 'build-started.json', core / 'build-closed.json', core / 'verify-closed.json', core / 'obj/tb_ventium'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    save(root / 'prepared.json', dict(command=command, pins=pins, changes=CHANGES, added_defines=[],
        parent=str(parent), directed_core=str(core), host=str(host), intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL, directed_model=CORE_MODEL, single_fill_model=BOARD_MODEL,
        functional_corpus_passed=True, canonical_gate_passed=False, qualification='UNQUALIFIED'))


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
        print('Four-file transfer prepared; canonical and hardware acceptance remain open.', flush=True)
        return 0
    return base.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
