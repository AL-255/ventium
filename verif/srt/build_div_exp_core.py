"""Transfer the tested exponent-width delta into the measured fetch-probe core.

Reuse the unchanged guarded compiler and private-header closure checks. This
does not qualify canonical correctness, whole-system behavior or FPGA timing.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
from types import SimpleNamespace

import prepare_div_exp_width as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import build_prime_query_payload_core as engine

PAYLOAD = 'rtl/fpu/fpu_srt_div.sv'
MODEL = '9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265'
TIMING = '2e4b5c7d84570dbac49585ce6106fc488a76e2f05fcdb9101e2fc5f7e327b673'
# The reused build method checks only these variant identities. Resource,
# input-pin, command, descriptor and generated-header checks stay unchanged.
engine.MODEL = MODEL
engine.recipe = SimpleNamespace(PAYLOAD=PAYLOAD)
common = engine.common
sha, load, save, stable = engine.sha, engine.load, engine.save, engine.stable


def prepare(args, root):
    parent, leaf, timing = [getattr(args, n).resolve(strict=True) for n in ('parent', 'leaf', 'timing')]
    assert not root.exists()
    before, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    assert sha(timing/'audit.json') == TIMING
    measured = load(timing/'audit.json')
    assert measured['passed'] and measured['native_exit'] == 0
    assert measured['constraints_mhz'] == dict(core=40, pl=100)
    assert abs(measured['unplaced_core_estimate_mhz'] - 30.487804878048784) < 1e-9
    checked = load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert checked['whole_engine'] and not checked['whole_core']
    labels = ('positive-shared', 'positive-split', 'zero-bias-split', 'unsigned-split', 'too-narrow-split')
    expected = []
    for label in labels:
        expected.extend([(label+'-build', 0), (label, 0 if label.startswith('positive') else 1)])
    assert [(r['label'], r['native_exit']) for r in checked['rows']] == expected
    pins = {**before['pins'], **checked['pins']}
    for row in checked['rows']:
        log = leaf/(row['label']+'.log')
        assert sha(log) == row['log_sha256']
        pins[str(log)] = row['log_sha256']
    for label in labels:
        marker = 'DIV-EXP-MITER-OK samples=29537 ' if label.startswith('positive') else 'DIV_EXP_STATE_MISMATCH'
        assert marker in (leaf/(label+'.log')).read_text()
    source = parent/'candidate'
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == before['pins'][str(p)] for p in files)
    changed = recipe.transform((source/PAYLOAD).read_text())
    assert changed == (leaf/'positive.sv').read_text()
    assert sha(source/'rtl/fpu/fpu_x87_pkg.sv') == recipe.PACKAGE
    flags = [s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_SHARED',
            'VEN_FP_LOAD_EARLY_CMD', 'VEN_SRT_REM_OPERAND_SPLIT'} <= set(definitions)
    assert not {'SYNTHESIS', 'VTM_NO_DPI'} & set(definitions)
    for p in (Path(__file__), Path(recipe.__file__), Path(engine.__file__), Path(common.__file__),
              REPO/'verif/l1/build_mc_branch_residency_core.py', parent/'build-started.json',
              parent/'build-closed.json', parent/'obj/tb_ventium', leaf/'closed.json', timing/'audit.json'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'candidate')
    (root/'candidate'/PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p) != sha(root/'candidate'/p)] == [PAYLOAD]
    host = root/('tb_div_exp_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'], host)
    command = common.relocate(before['command'], parent, root, Path(before['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    assert stable(pins)
    save(root/'prepared.json', dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODEL, definitions=definitions, changes=[PAYLOAD], compiler_started=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None))
    print('DIV-EXP-CORE-PREPARED files=195 defines=152 changes=1 compiler_started=false', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'build'))
    parser.add_argument('--out', type=Path, required=True)
    for name in ('parent', 'leaf', 'timing'):
        parser.add_argument('--'+name, type=Path)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.leaf and args.timing
        prepare(args, root)
        return 0
    return engine.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
