"""Transfer the checked three-file wide-response cut to the exact PC parent.

Timing-experiment admission only: canonical FAIL and physical acceptance remain
explicit. Reuse the unchanged bounded builder, including its native C++ audit.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_payload_current_soc as base
import prepare_fp_high_valid_cofactor as recipe

sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'
CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'
CHANGES=sorted(recipe.PARENTS)


def regressions(core, proof, fp):
    pins={}; stats={}; model=str(core/'obj/tb_ventium')
    closed,before=load(proof/'closed.json'),load(proof/'started.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['rows'])==12 and all(r['native_exit']==0 for r in closed['rows'])
    assert stable(before['pins'])
    pins.update(before['pins'])
    for p in (proof/'closed.json',proof/'started.json'): pins[str(p)]=sha(p)
    for label,count in [('fp',1536),*[(f'boundary-{n}',16) for n in (0,1,24,25,29,4093)],
                         ('integer',1024),('memory',288),('branch',2560),('faults',32)]:
        folder=fp if label=='fp' else proof/label
        start,done=load(folder/'started.json'),load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert start['models']['candidate']==model and len(done['measurements'])==count
        assert stable(start['pins'])
        rows=[r for r in done['measurements'] if r['model']=='candidate']
        assert len(rows)==count//2
        if label=='fp' or label.startswith('boundary-') or label=='integer':
            assert len(done['deltas'])==count//2 and all(r['saved_clocks']==0 for r in done['deltas'])
        if label=='faults':
            assert all(not r[k]['timed_out'] and r[k]['native_exit']==0
                       for r in done['measurements'] for k in ('gate','complete_uv_compare'))
            for name,digest in done['artifacts'].items():
                assert sha(folder/name)==digest; pins[str(folder/name)]=digest
        else:
            assert sum(r.get('paired_v',r.get('memory_v',0)) for r in rows)>0
        stats[label]=dict(records=sum(r['records'] for r in rows),measurements=count)
        pins.update(start['pins'])
        for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    held=proof/'held'; done,inputs=load(held/'result.json'),load(held/'inputs.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors'] and len(done['cases'])==48
    assert model in inputs and stable(inputs)
    assert all(r['measurements']['candidate']==r['measurements']['control'] for r in done['cases'])
    stats['held']=dict(records=sum(r['measurements']['candidate']['records'] for r in done['cases']))
    pins.update(inputs)
    for p in (held/'result.json',held/'inputs.json'): pins[str(p)]=sha(p)
    replay=proof/'replay'; start,done=load(replay/'started.json'),load(replay/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert start['models']['candidate']==model and len(done['rows'])==108 and done['records']==80800
    assert stable(start['pins']); pins.update(start['pins'])
    for p in (replay/'started.json',replay/'closed.json'): pins[str(p)]=sha(p)
    return pins,stats


def prepare(parent,core,proof,fp,root):
    assert not root.exists()
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    before,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged'] and stable(before['pins'])
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL and before['changes']==CHANGES
    verified=load(core/'verify-closed.json')
    assert verified['pins_unchanged'] and verified['canonical_gate_native_exit'] in (0,2)
    assert len(verified['deltas'])==20 and all(r['same_records'] for r in verified['deltas'])
    assert not verified['masks_or_goldens_or_bands_changed']
    pins,stats=regressions(core,proof,fp)
    source=parent/'source'; files=sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p)==old['pins'][str(p)] for p in files)
    for name in CHANGES:
        assert recipe.transform((source/name).read_text(),name)==(core/'candidate'/name).read_text()
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==CHANGES
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir(); shutil.copytree(source,root/'source')
    for name in CHANGES: shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in shared)
    host=root/'source/ao486-sim/ven'/('sim_fp_high_valid_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(name)
        if p.is_absolute(): pins[str(p)]=sha(p)
    for p in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(recipe.__file__),Path(base.__file__),Path(base.common.__file__),root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        statistics=stats,parent_model=PARENT_MODEL,directed_model=CORE_MODEL,
        canonical_gate_passed=verified['canonical_gate_passed'],qualification='UNQUALIFIED'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core','proof','fp'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and scratch.stat().st_dev!=base.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert all((args.parent,args.core,args.proof,args.fp))
        prepare(*(getattr(args,n).resolve(strict=True) for n in ('parent','core','proof','fp')),root)
        print('Prepared source-matched FP high-valid PC candidate; compiler not started.',flush=True)
        return 0
    # This existing builder launches the guarded command itself. Do not put it
    # under a second outer guard: it intentionally owns that complete lifecycle.
    return base.build(root)


if __name__=='__main__': raise SystemExit(main())
