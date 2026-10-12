"""Source-matched PC transfer for the exponent-width + memory-divide stage.

Preserve all 156 PC definitions, posted-16 transport, source closure and native
build guards. This admits a timing experiment, not a release: canonical FAIL,
standard-suite and physical-board requirements remain explicit.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base
REPO=base.REPO
sys.path[:0]=[str(REPO/'fp_shared/tb'),str(REPO/'verif/srt')]
import prepare_memdiv_capture as capture
import prepare_div_exp_width as exponent

sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='b598f07768e3e04483a3c11dca8d97ff35acd134d2b3f94a54fb56d3e1f21b71'
CORE_MODEL='be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10'
CHANGES=['fp_shared/ven_fp_top.sv','rtl/fpu/fpu_srt_div.sv']


def regressions(core):
    root=core.parent; pins={}; statistics={}
    for name,count in (('memdiv-fp-r2',1536),('memdiv-cold-full-r1',2048),('memdiv-faults-r1',32)):
        folder=root/name; before,done=load(folder/'started.json'),load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements'])==count and stable(before['pins'])
        assert before['models']['candidate']==str(core/'obj/tb_ventium')
        rows=[r for r in done['measurements'] if r['model']=='candidate']
        statistics[name]=dict(records=sum(r['records'] for r in rows),measurements=count)
        if name=='memdiv-faults-r1':
            assert all(not row[k]['timed_out'] and row[k]['native_exit']==0
                       for row in done['measurements'] for k in ('gate','complete_uv_compare'))
            assert all(sha(folder/p)==h for p,h in done['artifacts'].items())
        elif name=='memdiv-fp-r2':
            assert all(r['saved_clocks']==0 for r in done['deltas'])
        else:
            assert len(done['deltas'])==1024 and all(-16<=r['saved_clocks']<=0 for r in done['deltas'])
            assert sum(r['paired_v'] for r in rows)==1024
        pins.update(before['pins'])
        for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    folder=root/'memdiv-replay-r1'; before,done=load(folder/'started.json'),load(folder/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['rows'])==108 and done['records']==80800 and stable(before['pins'])
    assert before['models']['candidate']==str(core/'obj/tb_ventium')
    pins.update(before['pins'])
    for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    # Preserve byte-verified closed trace archives and their member indexes.
    for name,records in (('closed-memdiv-fp-text',416256),('closed-memdiv-cold-text',319488)):
        done=load(root/(name+'-closed.json'))
        assert done['completed'] and done['all_members_byte_verified'] and done['protected_pins_unchanged']
        assert sum(r['candidate_records'] for r in done['statistics'])==records
        assert sha(root/(name+'.tar.gz'))==done['archive_sha256']
        for suffix in ('-closed.json','-plan.json','.tar.gz'):
            p=root/(name+suffix); pins[str(p)]=sha(p)
    return pins,statistics


def prepare(parent,core,out):
    assert not out.exists()
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==PARENT_MODEL
    started,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0 and stable(started['pins'])
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')==CORE_MODEL
    assert started['changes']==[capture.PAYLOAD]
    pins,statistics=regressions(core)
    source=parent/'source'; files=sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p)==old['pins'][str(p)] for p in files)
    assert capture.transform((source/CHANGES[0]).read_text())==(core/'candidate'/CHANGES[0]).read_text()
    assert exponent.transform((source/CHANGES[1]).read_text())==(core/'candidate'/CHANGES[1]).read_text()
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102
    assert [n for n in shared if sha(source/n)!=sha(core/'candidate'/n)]==CHANGES
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    out.mkdir(); shutil.copytree(source,out/'source')
    for name in CHANGES: shutil.copyfile(core/'candidate'/name,out/'source'/name)
    assert all(sha(out/'source'/n)==sha(core/'candidate'/n) for n in shared)
    host=out/'source/ao486-sim/ven'/('sim_memdiv_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(out)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    definitions=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(definitions)==len(set(definitions))==156
    assert set(definitions)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (out/'defines.txt').write_text('\n'.join(sorted(definitions))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(name)
        if p.is_absolute(): pins[str(p)]=sha(p)
    for p in (*files,*(p for p in (out/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(capture.__file__),Path(exponent.__file__),Path(base.__file__),
              Path(base.common.__file__),out/'defines.txt',parent/'build-started.json',
              parent/'build-closed.json',parent/'build.log',core/'build-started.json',
              core/'build-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(out/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        statistics=statistics,parent_model=PARENT_MODEL,directed_model=CORE_MODEL,
        canonical_gate_passed=False,qualification='UNQUALIFIED'))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True); args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True); out=args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and out!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        prepare(args.parent.resolve(strict=True),args.core.resolve(strict=True),out)
        print('Prepared memory-divide PC transfer; compiler not launched.',flush=True)
    else: raise SystemExit(base.build(out))
