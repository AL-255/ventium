"""Transfer the tested raw-memory divide stage into the exact UV-fast core.

No feature/profile changes. Requires both complete FPU profiles and three
compiled bad variants to have closed with the intended result. The canonical
gate, system benchmarks and actual hardware acceptance remain separate.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys

import prepare_memdiv_capture as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import build_prime_query_payload_core as engine

MODEL = 'd7d683b3e1d2ea70586b56f095a86e11fc1e37fa6889050caaa2d5541f8e5b77'
NEW_TOP = 'de65098da526dd472b34ac0b46c664d55ef60617305cc93e7e68fafcf7a92c57'
engine.MODEL = MODEL
engine.recipe = recipe
common = engine.common
sha,load,save,stable = engine.sha,engine.load,engine.save,engine.stable


def prepare(args, root):
    parent, evidence = args.parent.resolve(strict=True), args.evidence.resolve(strict=True)
    assert not root.exists()
    before, built = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==sha(parent/'obj/tb_ventium')==MODEL
    pins = {**before['pins']}
    for name in ('base-r2','deployed-r1','live-bits-r1','reverse-r1','width-r1'):
        leaf = evidence/('memdiv-'+name)
        checked, started = load(leaf/'closed.json'),load(leaf/'started.json')
        positive = name in ('base-r2','deployed-r1')
        assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
        assert [(r['label'],r['native_exit']) for r in checked['rows']] == [
            ('build',0),('run',0 if positive else 1)]
        assert checked['pins']=={**started['pins'],
            str(leaf/'obj/Vtb_ven_fp_srt_top_ab'):sha(leaf/'obj/Vtb_ven_fp_srt_top_ab')}
        pins.update(checked['pins'])
        for row in checked['rows']:
            log = leaf/(row['label']+'.log')
            assert sha(log)==row['log_sha256']
            pins[str(log)]=row['log_sha256']
        log = (leaf/'run.log').read_text()
        if positive:
            assert 'FP-SRT-TOP-AB-OK matrix=12 checks=396' in log
            assert 'MEMDIV-CAPTURE-OK mem=8208 delayed=8192 fault=16 special=4096 starts=4096 resets=4 commands=32828' in log
            assert sha(leaf/'new.sv')==NEW_TOP
        else:
            assert 'MEMDIV_CAPTURE' in log, 'compiled mutant must fail operand ownership check'
        for path in (leaf/'started.json',leaf/'closed.json'):
            pins[str(path)] = sha(path)
    source = parent/'candidate'; files = common.candidate_files(source)
    assert len(files)==195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changed = recipe.transform((source/recipe.PAYLOAD).read_text())
    assert hashlib.sha256(changed.encode()).hexdigest()==NEW_TOP
    flags = [s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions = re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FP_SHARED',
            'VEN_FP_ARITH_STREAM','VEN_SRT_PAYLOAD_SELECT'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    deployed = load(evidence/'memdiv-deployed-r1/started.json')
    assert deployed['definitions']==definitions+['VEN_FP_PERF']
    for p in (Path(__file__),Path(recipe.__file__),Path(engine.__file__),Path(common.__file__),
              REPO/'verif/l1/build_mc_branch_residency_core.py',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')]==relative
    assert [p for p in relative if sha(source/p)!=sha(root/'candidate'/p)]==[recipe.PAYLOAD]
    host = root/('tb_memdiv_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'],host)
    command = common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)]=sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    assert stable(pins)
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.PAYLOAD],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print('MEMDIV-CORE-PREPARED files=195 defines=152 changes=1 compiler_started=false',flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--parent',type=Path)
    ap.add_argument('--evidence',type=Path)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert args.parent and args.evidence
        prepare(args,root); return 0
    return engine.build(root)


if __name__=='__main__': raise SystemExit(main())
