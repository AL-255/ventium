"""Transfer the proven RAW-storage specialization onto the retained-input PC.

Preserve the qualified boundary/input parent, all 157 definitions and all
other source bytes. Canonical and historical aggregate failures stay failures.
This builds a private diagnostic model, not a standard-suite accepted image.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_boundary_ui_soc as parent_build
import build_v_result_carry_soc as transfer

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_raw_prime_storage as recipe
import build_raw_prime_storage_core as core_build

ROOT = parent_build.ROOT
PARENT = ROOT/'boundary-ui-soc-r1'
CORE = ROOT/'raw-prime-storage-core-r1'
PARENT_MODEL = 'afb30954ff40f52727d680e12bcc2dd229f427dcf932f329685d0e109a4c2710'
CORE_MODEL = '41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b'
sha, load, save, stable = transfer.sha, transfer.load, transfer.save, transfer.stable


def check_delta(name, before, after):
    if name == recipe.FILE:
        assert recipe.transform(before.decode()).encode() == after
        return True
    assert before == after, 'unexpected source change: '+name
    return False


def check_equivalence(audit):
    assert audit['same_input_equivalence'] and audit['model'] == CORE_MODEL
    assert audit['parent'] == core_build.MODEL
    assert not any(audit[k] for k in ('legacy_aggregate_gate_passed',
        'canonical_gate_passed', 'standard_suite', 'hardware_acceptance'))
    assert audit['gameplay_ipc'] is None
    assert audit['totals'] == dict(stream_pairs=4240, func_records=641832,
        probe_pairs=4240, cycle_records=641832, actual_v_retirements=163956)
    assert audit['actual_parent_and_candidate_coverage'] == dict(clocks=16951320,
        agi=18172, ref=22872, retained=0, prime=132736, intent=5616,
        request=3072, accept=1872, shape_only=1536)


def evidence():
    pins = core_build.check_leaf(ROOT/'raw-prime-storage-leaf-r1')
    path = ROOT/'raw-prime-storage-core-checks-r1/parent-equivalence-audit.json'
    audit = load(path)
    check_equivalence(audit)
    pins.update(audit['pins']); pins[str(path)] = sha(path)
    path = ROOT/'raw-prime-storage-func-r1/audit.json'
    audit = load(path)
    assert audit['passed'] and audit['model'] == CORE_MODEL
    assert (audit['functional_passes'], audit['functional_records'],
            audit['v_retirements'], audit['unmasked_functional_passes']) == (108,80800,30132,105)
    assert not audit['canonical_gate_passed'] and not audit['standard_suite']
    pins.update(audit['pins']); pins.update(audit['artifacts']); pins[str(path)] = sha(path)
    for path in (ROOT/'boundary-ui-input-r1/audit.json',
                 PARENT/'coremark-ui-disabled-r1/audit.json'):
        audit = load(path)
        assert audit['passed'] and audit['model'] == PARENT_MODEL
        assert not audit['standard_suite']
        pins.update(audit.get('artifacts', {})); pins.update(audit.get('artifact_pins', {}))
        pins[str(path)] = sha(path)
    assert stable(pins)
    return pins


def prepare(root):
    assert root.parent == ROOT and not root.exists()
    before, done = load(PARENT/'build-started.json'), load(PARENT/'build-closed.json')
    assert done['passed'] and done['native_exit'] == 0 and done['inputs_unchanged']
    assert sha(PARENT/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == done['binary_sha256'] == PARENT_MODEL
    assert before['directed_model'] == core_build.MODEL and before['binding_read_wire'] == 'kb_fifo_rdreq'
    assert before['cycle_cost']['diagnostic_only'] and not before['canonical_gate_passed']
    assert before['changes'] == [parent_build.ui.PS2] and before['processor_rtl_changes'] == []
    start, done = load(CORE/'build-started.json'), load(CORE/'build-closed.json')
    assert done['passed'] and done['native_exit'] == 0 and done['pins_unchanged']
    assert sha(CORE/'obj/tb_ventium') == done['binary_sha256'] == CORE_MODEL
    assert start['parent_model'] == core_build.MODEL and start['changes'] == [recipe.FILE]
    assert stable(start['pins']) and stable(before['pins'])
    pins = evidence()
    source = PARENT/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == before['pins'][str(p)] for p in files)
    shared = before['intersecting_rtl_sources']
    assert len(shared) == 102
    assert [n for n in shared if check_delta(n, (source/n).read_bytes(),
            (CORE/'candidate'/n).read_bytes())] == [recipe.FILE]
    assert sha(source/parent_build.ui.PS2) == parent_build.ui.PS2_SHA
    root.mkdir(); shutil.copytree(source, root/'source')
    shutil.copyfile(CORE/'candidate'/recipe.FILE, root/'source'/recipe.FILE)
    assert [str(p.relative_to(source)) for p in files if check_delta(str(p.relative_to(source)),
        p.read_bytes(), (root/'source'/p.relative_to(source)).read_bytes())] == [recipe.FILE]
    assert all(sha(root/'source'/n) == sha(CORE/'candidate'/n) for n in shared)
    old_host = Path(before['host'])
    host = root/'source/ao486-sim/ven'/('sim_raw_prime_storage_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old_host, host)
    command = [s.replace(str(PARENT), str(root)) for s in before['command']]
    old_arg = str(root/old_host.relative_to(PARENT))
    assert command.count(old_arg) == 1
    command = [str(host) if s == old_arg else s for s in command]
    transfer.check_definitions(command, (PARENT/'defines.txt').read_text().splitlines())
    shutil.copyfile(PARENT/'defines.txt', root/'defines.txt')
    pins.update(before['pins']); pins.update(start['pins'])
    for p in (Path(__file__), Path(recipe.__file__), Path(core_build.__file__),
              Path(parent_build.__file__), Path(transfer.__file__), Path(transfer.base.__file__),
              root/'defines.txt', PARENT/'build-started.json', PARENT/'build-closed.json',
              PARENT/'build.log', PARENT/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',
              CORE/'build-started.json', CORE/'build-closed.json', CORE/'obj/tb_ventium',
              *(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=[recipe.FILE],
        added_defines=[], parent=str(PARENT), parent_model=PARENT_MODEL,
        directed_core=str(CORE), directed_model=CORE_MODEL, host=str(host),
        intersecting_rtl_sources=shared, processor_rtl_changes=[recipe.FILE],
        controller_sha256=parent_build.ui.PS2_SHA, binding_read_wire='kb_fifo_rdreq',
        host_headers=before['host_headers'], inherited_cycle_cost=before['cycle_cost'],
        input_parent=before['input_parent'], input_parent_model=before['input_parent_model'],
        legacy_aggregate_gate_passed=False, canonical_gate_passed=False,
        qualification='UNQUALIFIED', standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, note='RAW unreachable storage only; retained input and boundary timing CPU preserved.'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare','build'))
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.parent == ROOT and scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve() == scratch and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        prepare(root)
        print('Prepared RAW-storage/input PC; compiler not launched.', flush=True)
        return 0
    # This candidate's 20 canonical cycle streams are exactly parent-identical;
    # the ancestor boundary cost stays recorded separately, never waived here.
    return transfer.base.build(root)


if __name__ == '__main__': raise SystemExit(main())
