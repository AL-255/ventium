"""Build the request-equivalent RAW next-read/read-store-pair timing candidate."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
from types import SimpleNamespace

import build_fp_high_valid_core as builder
import prepare_next_pair_cofactor as recipe
from build_next_pair_probe import MODEL

HERE = Path(__file__).resolve().parent
sha,load,save,stable = builder.sha,builder.load,builder.save,builder.stable


def prepare(parent, proof, root):
    old,built = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    proven = load(proof)
    assert proven['passed'] and proven['pins_unchanged'] and proven['simulation_only']
    assert proven['coverage']['retained'] == 0 and sum(proven['counts'].values()) == 4240
    assert all(proven['coverage'][k] > 0 for k in ('agi','ref','prime','intent','accept','shape_only'))
    assert proven['negative']['expected_failure'] and proven['negative']['native_exit'] == 1
    pins = {**old['pins'],**proven['pins']}
    source = parent/'candidate'; files = builder.base.common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    changed = recipe.transform((source/recipe.PAYLOAD).read_text())
    # Retain the actual predicate counters for directed candidate/control tests.
    # Both this probe and the full request-equivalence assertion are excluded
    # from hardware; the sole synthesized delta is the redundant RAW guard.
    changed += '\n' + (HERE/'next_pair_overlap_probe.svh').read_text()
    flags = [s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_RAW_V_READ_PRIME','VEN_P54_LOAD_STORE_PAIR','VEN_L1_AXI',
            'VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_UOPCACHE'} & set(definitions)
    for p in (Path(__file__).resolve(),Path(recipe.__file__),Path(builder.__file__),
              Path(builder.base.__file__),Path(builder.base.common.__file__),
              HERE/'build_next_pair_probe.py',HERE/'next_pair_overlap_probe.svh',
              HERE/'build_mc_branch_residency_core.py',proof,parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in builder.base.common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p) != sha(root/'candidate'/p)] == [recipe.PAYLOAD]
    host = root/('tb_next_pair_cut_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command = builder.base.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.PAYLOAD],compiler_started=False,
        probe_audit=str(proof),canonical_gate_passed=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('NEXT-PAIR-COFACTOR-PREPARED '+str(root),flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for k in ('parent','proof'): ap.add_argument('--'+k,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch
    assert scratch.stat().st_dev != builder.base.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.proof and not root.exists()
        prepare(args.parent.resolve(strict=True),args.proof.resolve(strict=True),root)
        return 0
    builder.MODEL = MODEL
    builder.recipe = SimpleNamespace(PARENTS={recipe.PAYLOAD:recipe.PARENT})
    return builder.build(root)


if __name__ == '__main__': raise SystemExit(main())
