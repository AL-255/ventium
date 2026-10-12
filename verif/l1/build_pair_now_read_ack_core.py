"""Prepare/build one private core using the existing guarded builder lifecycle.

Only the immediate V-load acceptance consumer changes. This command cannot
launch synthesis, routing or deployment, and build refuses a live Vivado.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil

import build_prime_query_payload_core as base
import prepare_pair_now_read_ack as recipe

MODEL = 'e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525'
BASE_SHA = '2c9dc4d236562fe6b4433266f5896b4625c63c3848c1f8125a531bda71baa18e'
sha,load,save,stable = base.sha,base.load,base.save,base.stable


def prepare(parent,root):
    assert not root.exists()
    before,built = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    source=parent/'candidate'; files=base.common.candidate_files(source)
    assert len(files) == 195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changed=recipe.transform((source/recipe.PAYLOAD).read_text())
    assert changed.replace(recipe.NEW+recipe.WITNESS,recipe.OLD) == (source/recipe.PAYLOAD).read_text()
    flags=[s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FP_LOAD_EARLY_CMD',
            'VEN_P54_DUAL_BYTE_LOAD_PAIR','VEN_RAW_V_READ_PRIME'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    pins=dict(before['pins'])
    for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),
                 Path(base.common.__file__).resolve(),parent/'obj/tb_ventium',
                 parent/'build-started.json',parent/'build-closed.json'):
        pins[str(path)]=sha(path)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in base.common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p)!=sha(root/'candidate'/p)] == [recipe.PAYLOAD]
    host=root/('tb_pair_now_read_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'],host)
    command=base.common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)]=sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.PAYLOAD],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print('PAIR-NOW-READ-ACK-PREPARED '+str(root),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build'))
    parser.add_argument('--parent',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root != scratch
    assert scratch.stat().st_dev != base.REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert sha(Path(base.__file__)) == BASE_SHA
    if args.action=='prepare':
        assert args.parent is not None
        prepare(args.parent.resolve(strict=True),root); return 0
    # Reuse the unchanged exclusive-lock, descriptor, cgroup, no-Vivado,
    # compiler identity, local harness/header and source-hash checks.
    base.MODEL=MODEL; base.recipe=recipe
    return base.build(root)


if __name__ == '__main__': raise SystemExit(main())
