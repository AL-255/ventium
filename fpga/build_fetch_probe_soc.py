"""Transfer the checked fetch-probe payload into the source-matched PC model.

This is timing-experiment admission, not canonical/full-suite/FPGA acceptance.
Reuse the established guarded native build, warning and private-header checks.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_load_read_ack_soc as prior
base=prior.base; REPO=base.REPO
sys.path.insert(0,str(REPO/'verif/fetchguard'))
import prepare_probe_payload as recipe
sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='89ebdd625be3f65e97c1ddafee6e166084ed3978c27d96f5f96b6509144f0a09'
CORE_MODEL='9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265'


def regressions(core):
    root=core.parent; pins={}; statistics={}
    for name,count in (('probe-memory-r1',288),('probe-fp-r2',1536),
                       ('probe-integer-r1',1024),('probe-faults-r1',32)):
        folder=root/name; before,done=load(folder/'started.json'),load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements'])==count and stable(before['pins'])
        assert before['models']['candidate']==str(core/'obj/tb_ventium')
        if name=='probe-faults-r1':
            assert all(not row[k]['timed_out'] and row[k]['native_exit']==0
                       for row in done['measurements'] for k in ('gate','complete_uv_compare'))
            assert all(sha(folder/p)==h for p,h in done['artifacts'].items())
        rows=[r for r in done['measurements'] if r['model']=='candidate']
        statistics[name]=dict(records=sum(r['records'] for r in rows),measurements=count)
        pins.update(before['pins'])
        for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    folder=root/'probe-held-r1'; done,inputs=load(folder/'result.json'),load(folder/'inputs.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors']
    assert len(done['cases'])==48 and str(core/'obj/tb_ventium') in inputs and stable(inputs)
    statistics['held']=dict(records=sum(r['measurements']['candidate']['records'] for r in done['cases']))
    pins.update(inputs)
    for p in (folder/'inputs.json',folder/'result.json'): pins[str(p)]=sha(p)
    folder=root/'probe-boundary-r1'; before,done=load(folder/'started.json'),load(folder/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors'] and len(done['rows'])==88
    assert done['candidate_records']==21832 and done['paired_v']==4968 and done['probe_witnesses']>0
    assert stable(before['pins']) and str(core/'obj/tb_ventium') in before['pins']
    statistics['boundary']=dict(records=done['candidate_records'],probe_witnesses=done['probe_witnesses'])
    pins.update(before['pins'])
    for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    replay=root/'probe-canonical-replay-r1'; before,done=load(replay/'started.json'),load(replay/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['rows'])==108 and done['records']==80800 and stable(before['pins'])
    assert before['models']['candidate']==str(core/'obj/tb_ventium')
    pins.update(before['pins'])
    for p in (replay/'started.json',replay/'closed.json'): pins[str(p)]=sha(p)
    # Traces were re-compared in full before lossless archiving. Preserve their
    # immutable archive and member/hash index, not nonexistent unpacked copies.
    archive=load(root/'closed-probe-corpora-text-closed.json')
    assert archive['completed'] and archive['all_members_byte_verified'] and archive['protected_pins_unchanged']
    assert sha(root/'closed-probe-corpora-text.tar.gz')==archive['archive_sha256']
    assert sum(r['candidate_records'] for r in archive['statistics'])==408992
    for name in ('closed-probe-corpora-text-closed.json','closed-probe-corpora-text-plan.json',
                 'closed-probe-corpora-text.tar.gz','audit_archive_probe_corpora.py'):
        pins[str(root/name)]=sha(root/name)
    return pins,statistics


def prepare(parent,core,out):
    assert not out.exists()
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==PARENT_MODEL
    started,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0 and stable(started['pins'])
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')==CORE_MODEL
    assert started['changes']==[recipe.PAYLOAD]
    pins,statistics=regressions(core)
    source=parent/'source'; files=sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p)==old['pins'][str(p)] for p in files)
    assert recipe.transform((source/recipe.PAYLOAD).read_text())==(core/'candidate'/recipe.PAYLOAD).read_text()
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102
    assert [n for n in shared if sha(source/n)!=sha(core/'candidate'/n)]==[recipe.PAYLOAD]
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    out.mkdir(); shutil.copytree(source,out/'source')
    shutil.copyfile(core/'candidate'/recipe.PAYLOAD,out/'source'/recipe.PAYLOAD)
    assert all(sha(out/'source'/n)==sha(core/'candidate'/n) for n in shared)
    host=out/'source/ao486-sim/ven'/('sim_fetch_probe_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
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
              Path(recipe.__file__),Path(prior.__file__),Path(base.__file__),out/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(out/'prepared.json',dict(command=command,pins=pins,changes=[recipe.PAYLOAD],added_defines=[],
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
        print('Prepared source-matched fetch-probe PC; compiler not launched.',flush=True)
    else: raise SystemExit(base.build(out))
