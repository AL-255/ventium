"""Cold system A/B, full QEMU state and every retirement clock at AXI 0/7/31.

Uses unmodified repository BIOS fixtures, real OUT debug-exit, no checkpoints,
forced core state, guest patches or fault/flag masking. Failed old-parent tests
remain failures. Native system-state witness coverage is reported separately.
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import importlib.util
import inspect
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare_system_read_ack as recipe
from run_system_read_ack_leaf import MODEL as PARENT
from run_system_read_ack_leaf import lifecycle

REPO=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(REPO/'verif/diff')]
import compare
import tracefmt
spec=importlib.util.spec_from_file_location('native_system',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
MODEL='005d0f17a3360588d6b67c5f49267db785cb7cc07893ee6a14dc42cafe615aeb'
CASES='pseg ppage pfault pintr pcpl ptask pv86 pxc04 pxfrag pxwalkd pcgparam pretfoutpg piopermwrap pjmpgate pxfer'.split()
CPUS=(4,5,6,7,8,9,12,13,15,16,17,18,19,20,21)
sha=lifecycle.sha


def observe_native_affinity(pid,argv,receipt):
    models=[Path(a) for a in argv if Path(str(a)).name=='tb_ventium']
    if not models or receipt.get('native_affinity_observed'): return
    assert len(models)==1 and argv[:2]==['taskset','-c']
    try:
        if Path('/proc',str(pid),'exe').resolve(strict=True)!=models[0]: return
        observed=sorted(os.sched_getaffinity(pid))
        assert observed==[int(argv[2])], observed
        receipt.update(native_affinity_observed=True,native_affinity=observed,
                       native_executable=str(models[0]))
    except (ProcessLookupError,FileNotFoundError): pass


def observed_supervisor():
    # Add a read-only /proc observation inside the existing unreaped-child
    # loop. Keep its ownership-checked timeout/group cleanup and final wait.
    source=inspect.getsource(native.supervise)
    old='                    if time.monotonic() >= deadline:\n'
    source=recipe.once(source,old,'                    observe_native_affinity(process.pid,argv,receipt)\n'+old)
    namespace=dict(native.__dict__,observe_native_affinity=observe_native_affinity)
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['supervise']


def save(path,value):
    with path.open('x') as f: json.dump(value,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','core','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args()
    parent,core=a.parent.resolve(strict=True),a.core.resolve(strict=True)
    out=a.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and set(CPUS)<=os.sched_getaffinity(0)
    assert os.environ['INVOCATION_ID']
    start=json.loads((core/'build-started.json').read_text())
    built=json.loads((core/'build-closed.json').read_text())
    old=json.loads((parent/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert start['parent_model']==sha(parent/'obj/tb_ventium')==PARENT
    assert start['definitions']==old['definitions'] and len(start['definitions'])==153
    assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'}<=set(start['definitions'])
    for n in recipe.PARENTS:
        assert (core/'candidate'/recipe.PREFIX/n).read_text()==recipe.transform(
            (parent/'candidate'/recipe.PREFIX/n).read_text(),n)
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    gen=REPO/'verif/qemu-trace/gen_trace.py'
    pins=dict(start['pins'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(compare.__file__),
              Path(tracefmt.__file__),Path(lifecycle.__file__),qemu,gen,
              core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=sha(p)
    manifests={}
    for case in CASES:
        folder=REPO/'verif/sys/tests'/case
        manifest=json.loads((folder/'manifest.json').read_text()); manifests[case]=manifest
        assert manifest['image_mode']=='bios' and manifest['image_bytes']==65536
        for p in (folder/'manifest.json',folder/manifest['src'],folder/manifest['linker']):
            pins[str(p)]=sha(p)
        assert not re.search(r'^\s*(#include|\.include)',(folder/manifest['src']).read_text(),re.M)
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir()
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        models=dict(parent=PARENT,candidate=MODEL),cases=CASES,cpus=CPUS,latencies=[0,7,31],
        defines=start['definitions'],rtl_modes=['cycle-func','cycle'],no_step=True))
    group=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().strip().split('::',1)[1].lstrip('/')
    supervise=observed_supervisor()

    def run(folder,name,command,expected=0):
        stdout,stderr=folder/(name+'.stdout'),folder/(name+'.stderr')
        receipt=supervise(command,stdout,stderr,folder/(name+'.native.json'),90)
        if receipt['actual_return_code']!=expected:
            raise ValueError((name,receipt['actual_return_code'],expected))
        if any(Path(str(a)).name=='tb_ventium' for a in command):
            assert receipt.get('native_affinity_observed'), (name,'no actual model affinity observation')
        return stdout.read_text(),stderr.read_text()

    def check(index,case):
        folder=out/case; folder.mkdir()
        td=REPO/'verif/sys/tests'/case; m=manifests[case]; cpu=CPUS[index]
        prefix=['taskset','-c',str(cpu)]
        cc=['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie','-Wall']
        run(folder,'assemble',prefix+cc+['-c',str(td/m['src']),'-o',str(folder/'test.o')])
        run(folder,'link',prefix+cc+['-static','-no-pie','-Wl,-T,'+str(td/m['linker']),
            '-Wl,--build-id=none',str(folder/'test.o'),'-o',str(folder/'test.elf')])
        image=folder/'test.bin'
        run(folder,'binary',prefix+['objcopy','-O','binary',str(folder/'test.elf'),str(image)])
        assert image.stat().st_size<=65536
        with image.open('r+b') as f: f.truncate(65536)
        run(folder,'qemu-free',prefix+[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
            '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],m['exit_code'])
        goldfile=folder/'gold.vtrace'
        run(folder,'gold',prefix+[sys.executable,'-B',gen,'--qemu',qemu,'--cpu','pentium','--system',
            '--image',image,'--image-mode','bios','--out',goldfile,'--max-insn',str(m['max_insn']),
            '--port',str(41800+index)])
        gold=tracefmt.read_trace(str(goldfile))
        assert 0<len(gold.records)<m['max_insn']
        rows=[]; errors=[]; states=set(); walk=set()
        for latency in (0,7,31):
            traces={}
            for label,model in [('parent',parent/'obj/tb_ventium'),('candidate',core/'obj/tb_ventium')]:
                traces[label]={}
                for mode in ('cycle-func','cycle'):
                    name=f'{label}-{latency}-{mode}'; output=folder/(name+'.vtrace')
                    stdout,stderr=run(folder,name,prefix+['env',f'AXI_RLAT={latency}',f'AXI_WLAT={latency}',
                        model,'--system','--cosim','--'+mode,'--l1-axi','--image',image,'--out',output,
                        '--max-insn',str(m['max_insn']),'--max-cycles','5000000','--quiesce','4096',
                        '+ven_faultlog','+ven_system_read_ack_witness'],m['exit_code'])
                    tr=tracefmt.read_trace(str(output)); traces[label][mode]=tr.records
                    assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                    if mode=='cycle-func':
                        grade=native.grade_native(tr,stdout,stderr,m['exit_code'],m['exit_code'],m['max_insn'])
                        with (folder/(name+'.diff')).open('x') as f:
                            differences=compare.compare_func(gold,tr,False,0xffffffff,False,20,f,sys_both=True)
                        if differences: errors.append(dict(case=case,run=name,differential= differences))
                    else:
                        grade=dict(records=len(tr.records),v=sum(r.get('pipe')=='V' and r.get('paired',False) for r in tr.records))
                    rows.append(dict(case=case,label=label,latency=latency,mode=mode,**grade))
                    if label=='candidate':
                        for st,ph in re.findall(r'\[SYSTEM-READ-ACK\] state=(\w+) walk=(\d+)',stdout):
                            states.add(st)
                            if st=='S_WALK': walk.add(int(ph))
            if traces['parent']!=traces['candidate']:
                errors.append(dict(case=case,latency=latency,error='parent state/cycle mismatch'))
        result=dict(passed=not errors,errors=errors,rows=rows,states=sorted(states),walk_read_phases=sorted(walk))
        save(folder/'closed.json',result)
        return result

    result=dict(passed=False,errors=[],rows=[],coverage_states=[],gameplay_ipc=None,
        standard_suite=False,hardware_acceptance=False,canonical_gate_passed=False)
    begin=time.monotonic(); states=set(); walk=set()
    with ThreadPoolExecutor(max_workers=len(CPUS)) as pool:
        futures={pool.submit(check,i,c):c for i,c in enumerate(CASES)}
        for f in as_completed(futures):
            try:
                row=f.result(); result['rows']+=row['rows']; result['errors']+=row['errors']
                states.update(row['states']); walk.update(row['walk_read_phases'])
            except Exception as error:
                result['errors'].append(dict(case=futures[f],error=repr(error),traceback=traceback.format_exc()))
    result['coverage_states']=sorted(states)
    result['uncovered_read_states']=sorted(set(recipe.STATES)-states)
    result['walk_read_phases']=sorted(walk)
    result['candidate_v_retirements']=sum(r.get('v',0) for r in result['rows'] if r['label']=='candidate')
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['memory_events']=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
    result['passed']=(not result['errors'] and len(result['rows'])==len(CASES)*12 and
        result['candidate_v_retirements']>0 and result['pins_unchanged'] and
        all(result['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill')))
    result['all_read_owners_exercised']=not result['uncovered_read_states'] and walk=={0,2}
    result['seconds']=time.monotonic()-begin
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
