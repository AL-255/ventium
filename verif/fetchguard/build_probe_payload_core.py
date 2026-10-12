"""Build the exact one-file fetch-probe derivative using the existing guard.

Reuse the load-ACK parent's established build/closure implementation; only
preparation/admission differs. No new define or compiler option is introduced.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys

import prepare_probe_payload as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import build_prime_query_payload_core as engine

# The reused build method validates this payload against the preparation record.
engine.recipe = recipe
common = engine.common
sha,load,save,stable = engine.sha,engine.load,engine.save,engine.stable


def prepare(args, root):
    parent=args.parent.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    assert not root.exists()
    before,built=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==sha(parent/'obj/tb_ventium')==engine.MODEL
    checked=load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['whole_core']
    assert [(r['mode'],r['native_exit']) for r in checked['rows']]==[
        ('positive',0),('previous-page',1),('wrong-extent',1),('data-side',1),('lost-wrap',1)]
    assert [(r['mode'],r['answer'],r['native_exit']) for r in checked['queries']]==[
        ('positive','unsat',0),('previous-page','sat',0),('lost-wrap','sat',0)]
    assert checked['coverage']['checks']==278528 and all(checked['coverage'].values())
    pins=dict(checked['pins'])
    for row in checked['rows']+checked['queries']: pins.update(row['artifacts'])
    assert stable(pins)
    source=parent/'candidate'; files=common.candidate_files(source)
    assert len(files)==195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changed=recipe.transform((source/recipe.PAYLOAD).read_text())
    assert changed==(leaf/'core.sv').read_text()
    flags=[s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME'}<=set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'}&set(definitions)
    pins.update({str(p):sha(p) for p in files})
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(engine.__file__).resolve(),
              Path(common.__file__).resolve(),REPO/'verif/l1/build_mc_branch_residency_core.py',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
              leaf/'closed.json',REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')]==relative
    assert [p for p in relative if sha(source/p)!=sha(root/'candidate'/p)]==[recipe.PAYLOAD]
    host=root/('tb_probe_payload_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'],host)
    command=common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)]=sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=engine.MODEL,definitions=definitions,changes=[recipe.PAYLOAD],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print('FETCH-PROBE-CORE-PREPARED files=195 defines=152 changes=1 compiler_started=false',flush=True)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--parent',type=Path); ap.add_argument('--leaf',type=Path)
    args=ap.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert args.parent and args.leaf
        prepare(args,root); return 0
    return engine.build(root)


if __name__=='__main__': raise SystemExit(main())
