"""Prepare a private full-PC derivative with only the qualified AUX owner fix.

No CPU/FPU/cache/transport or define changes. The separate guarded build action
uses the existing compiler lifecycle; do not launch it while Vivado is active.
Select the closed parent explicitly; an older peripheral preparation is not a
substitute for carrying the current processor fixes into the new full-PC model.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/ps2_ui'))
import audit_aux_status as evidence
import prepare_aux_status as recipe

PARENT_MODEL = '593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9'
CORE_MODEL = 'c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f'
PROFILES = {
    'early-bus': (PARENT_MODEL, CORE_MODEL),
    'pipe-wait': (
        '55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce',
        'c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a'),
}
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
FILE = '3rd-party/ao486_MiSTer/rtl/soc/ps2.v'
sha, load, save, stable = base.sha, base.load, base.save, base.stable


def check_delta(name, before, after):
    if name == FILE:
        assert after == recipe.transform(before.decode()).encode()
        return True
    assert before == after, 'unreviewed source change: '+name
    return False


def check_parent(profile, old, closed, binary_hash):
    """Admit only the chosen, actually built processor source closure."""
    assert profile in PROFILES, 'unknown source profile'
    parent_model, core_model = PROFILES[profile]
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert binary_hash == closed['binary_sha256'] == parent_model, 'wrong PC parent'
    assert old['directed_model'] == core_model, 'wrong directed-core parent'
    return parent_model, core_model


def check_destination(root, *inputs):
    """Never copy a source tree into itself (or into another evidence tree)."""
    root = root.resolve()
    for source in inputs:
        source = source.resolve()
        assert not root.is_relative_to(source) and not source.is_relative_to(root), \
            'source/output overlap: '+str(source)


def prepare(parent, proof, root, profile='early-bus'):
    assert not root.exists() and sha(base.__file__) == BUILDER
    check_destination(root, parent, proof, REPO)
    micro = evidence.audit(proof)
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    parent_model, core_model = check_parent(profile, old, closed,
        sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'))
    assert stable(old['pins'])
    core = Path(old['directed_core'])
    check_destination(root, core)
    assert sha(core/'obj/tb_ventium') == core_model
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == old['pins'][str(p)] for p in files)
    assert sha(source/FILE) == recipe.PARENT
    for name in ('soc/iobus.v', 'common/simple_fifo.v'):
        assert (source/('3rd-party/ao486_MiSTer/rtl/'+name)).read_bytes() == (proof/Path(name).name).read_bytes()
    shared = old['intersecting_rtl_sources']
    assert len(shared) == 102 and all(sha(source/n) == sha(core/'candidate'/n) for n in shared)
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    root.mkdir()
    shutil.copytree(source, root/'source')
    (root/'source'/FILE).write_bytes((proof/'ps2.v').read_bytes())
    changed = []
    for p in files:
        name = str(p.relative_to(source))
        if check_delta(name, p.read_bytes(), (root/'source'/name).read_bytes()): changed.append(name)
    assert changed == [FILE]
    host = root/'source/ao486-sim/ven'/('sim_aux_status_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    definitions = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(definitions) == len(set(definitions)) == 157
    assert set(definitions) == set((parent/'defines.txt').read_text().splitlines())
    assert {'VEN_KBC_FAST', 'VEN_KBD_AUTOACK', 'VEN_X87_MF_STRICT', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH'} <= set(definitions)
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    assert command[:2] == [str(REPO/'tools/build_scope.sh'), '--'] and '600s' in command
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    i = command.index('taskset'); assert command[i+1:i+3] == ['-c', '0-9,12-31']
    shutil.copyfile(parent/'defines.txt', root/'defines.txt')
    pins = old['pins'] | micro['pins']
    for p in (Path(__file__), Path(base.__file__), Path(base.common.__file__),
              root/'defines.txt', parent/'build-started.json', parent/'build-closed.json', parent/'build.log',
              parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', core/'obj/tb_ventium',
              *(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'aux-micro-audit.json', micro)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=[FILE], added_defines=[],
        parent=str(parent), parent_profile=profile, parent_model=parent_model,
        directed_core=str(core), directed_model=core_model,
        host=str(host), intersecting_rtl_sources=shared, core_sources_unchanged=True,
        canonical_gate_passed=False, qualification='UNQUALIFIED', gameplay_ipc=None,
        standard_suite=False, hardware_acceptance=False, aux_micro_executions=3984,
        included_fixes=['status AUX bit follows the latched output-byte owner']))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    ap.add_argument('--parent-profile', choices=tuple(PROFILES), default='early-bus')
    for name in ('parent', 'proof'): ap.add_argument('--'+name, type=Path)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3 and sha(base.__file__) == BUILDER
    if args.action == 'prepare':
        assert args.parent and args.proof
        prepare(args.parent.resolve(strict=True), args.proof.resolve(strict=True), root, args.parent_profile)
        print('Prepared one peripheral HDL delta; compiler not launched.', flush=True)
        return 0
    return base.build(root)


if __name__ == '__main__': raise SystemExit(main())
