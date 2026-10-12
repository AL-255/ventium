"""Build explicit shared-port intent arbitration after real cache microbenches."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil

import build_fp_high_valid_core as builder
import prepare_pair_intent as recipe

MODEL = '7ce9cfa450ee674e59fc296503153ac9c9fd24b03f52f9175e04bce5eb482f32'
sha,load,save,stable = builder.sha,builder.load,builder.save,builder.stable


def prepare(parent, proof, root):
    old,built = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    checked = load(proof/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['rows']) == 7
    assert sum(not r['mutant'] and r['native_exit'] == 0 for r in checked['rows']) == 6
    assert checked['rows'][-1]['mutant'] and checked['rows'][-1]['native_exit'] != 0
    pins = {**old['pins'],**checked['pins']}
    assert stable(pins)
    source = parent/'candidate'; files = builder.base.common.candidate_files(source)
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    changed = {n:recipe.transform((source/n).read_text(),n) for n in recipe.PARENTS}
    assert changed['rtl/mem/ven_l1d.sv'] == (proof/'ven_l1d.sv').read_text()
    for row in checked['rows']:
        folder = proof/row['label']
        assert sha(folder/'obj/Vtb_l1d_pair_store') == row['binary_sha256']
        assert sha(folder/'run.log') == row['log_sha256']
        for p in (folder/'closed.json',folder/'run.log',folder/'build.log'):
            pins[str(p)] = sha(p)
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
              proof/'closed.json',parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    for n,t in changed.items(): (root/'candidate'/n).write_text(t)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in builder.base.common.candidate_files(root/'candidate')] == relative
    assert sorted(p for p in relative if sha(source/p) != sha(root/'candidate'/p)) == sorted(changed)
    host = root/('tb_pair_intent_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command = builder.base.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=sorted(changed),compiler_started=False,
        cache_proof=str(proof),canonical_gate_passed=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('PAIR-INTENT-CORE-PREPARED '+str(root),flush=True)


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
    builder.recipe = recipe
    return builder.build(root)


if __name__ == '__main__': raise SystemExit(main())
