"""Build a simulation-only overlap probe from the closed backing-payload core.

No hardware behavior changes. The fresh model inherits all 152 defines and
the guarded/private-harness build contract. An assertion failure is evidence
against the proposed timing cut, not a test to waive.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
from types import SimpleNamespace

import build_fp_high_valid_core as builder

MODEL = '4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'
PAYLOAD = 'rtl/core/core_mem_chain.svh'
PARENT_SHA = '6e888ab63a31a9100f1e4afd6ee61159111b10518d336ea5fdf0a1aa915ecde4'
HERE = Path(__file__).resolve().parent
sha, load, save, stable = builder.sha, builder.load, builder.save, builder.stable


def transform(text):
    assert hashlib.sha256(text.encode()).hexdigest() == PARENT_SHA
    anchor = '  assign mem_next_req = agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer;\n'
    assert text.count(anchor) == 1
    probe = (HERE/'next_pair_overlap_probe.svh').read_text()
    changed = text.replace(anchor, anchor + probe)
    assert changed.replace(probe, '', 1) == text
    return changed


def prepare(parent, root):
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    source = parent/'candidate'; files = builder.base.common.candidate_files(source)
    assert len(files) == 195
    pins = dict(old['pins'])
    assert all(sha(p) == pins[str(p)] for p in files)
    flags = [s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_RAW_V_READ_PRIME', 'VEN_P54_LOAD_STORE_PAIR', 'VEN_RAW_AGI_PRIME',
            'VEN_REF_OPERAND_PRIME', 'VEN_RAW_HELD_READ_PRIME', 'VEN_L1_AXI',
            'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_UOPCACHE'} & set(definitions)
    for p in (Path(__file__).resolve(), HERE/'next_pair_overlap_probe.svh',
              Path(builder.__file__), Path(builder.base.__file__),
              Path(builder.base.common.__file__), HERE/'build_mc_branch_residency_core.py',
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    changed = transform((source/PAYLOAD).read_text())
    root.mkdir(); shutil.copytree(source, root/'candidate')
    (root/'candidate'/PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in builder.base.common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p) != sha(root/'candidate'/p)] == [PAYLOAD]
    host = root/('tb_next_pair_probe_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = builder.base.common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p): sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json', dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[PAYLOAD],compiler_started=False,
        simulation_only=True,canonical_gate_passed=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None))
    print('NEXT-PAIR-PROBE-PREPARED '+str(root),flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare','build'))
    parser.add_argument('--parent', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch
    assert scratch.stat().st_dev != builder.base.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and not root.exists()
        prepare(args.parent.resolve(strict=True), root)
        return 0
    # Reuse the existing native build safety/closure checks, not its recipe.
    builder.MODEL = MODEL
    builder.recipe = SimpleNamespace(PARENTS={PAYLOAD: PARENT_SHA})
    return builder.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
