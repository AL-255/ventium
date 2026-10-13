"""Cold environment-store page faults on the current UV-fast AXI model.

Four native workers, no RTL build, snapshots, trace filtering or oracle edits.
Failures are retained even when the guest and host exits differ.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt
import prepare_write_class as recipe


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f: json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--core', type=Path)
    a = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = a.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == set(range(13,17))
    assert shutil.disk_usage(scratch).free > 4*1024**3 + 512*1024**2
    original = scratch/'ventium-data-size.v2HaTO2X/core-r1'
    core = a.core.resolve(strict=True) if a.core else original
    model = core/'obj/tb_ventium'
    before, built = [json.loads((core/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(model) == built['binary_sha256']
    parent_model='fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'
    repaired=core!=original
    witness_images={}
    if repaired:
        parent=json.loads((original/'build-started.json').read_text())
        assert before['parent_model']==parent_model and before['changes']==[recipe.FILE]
        parent_files={str(Path(p).relative_to(original/'candidate')):h for p,h in parent['pins'].items()
                      if Path(p).is_relative_to(original/'candidate')}
        actual_files={str(Path(p).relative_to(core/'candidate')):h for p,h in before['pins'].items()
                      if Path(p).is_relative_to(core/'candidate')}
        assert len(parent_files)==len(actual_files)==195 and parent_files.keys()==actual_files.keys()
        assert [n for n in parent_files if parent_files[n]!=actual_files[n]]==[recipe.FILE]
        assert (core/'candidate'/recipe.FILE).read_text()==recipe.transform((original/'candidate'/recipe.FILE).read_text())
        old=json.loads((scratch/'ventium-data-size.v2HaTO2X/envfault-r2/closed.json').read_text())
        witness_images={tuple(sorted(r['case'].items())):r['image_sha256'] for r in old['rows']}
        assert len(witness_images)==44
    else:
        assert sha(model)==parent_model
    defs = set(before['definitions'])
    assert len(defs) == 152 and {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
        'VEN_FP_SHARED','VEN_L1_AXI'} <= defs
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_CACHE_HALF'} & defs
    qroot = scratch/'ventium-qemu-env.oo7IGAh3/build-r4'
    qb = json.loads((qroot/'closed.json').read_text())
    qemu = Path(next(r['binary'] for r in qb['rows'] if r['sha256'] ==
        'f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202'))
    assert sha(qemu) == 'f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202'
    bios = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios'
    producer, compare = REPO/'verif/qemu-trace/gen_trace.py', REPO/'verif/diff/compare.py'
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    pins = dict(before['pins'])
    for p in (Path(__file__), Path(recipe.__file__), HERE/'fault.S', linker, producer, compare, Path(tracefmt.__file__),
              model, qemu, qroot/'closed.json', core/'build-started.json',core/'build-closed.json',
              bios/'vgabios-stdvga.bin'):
        pins[str(p)] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    cases = [dict(FULL=f,ENV16=w,HEAD=h,PRESENT=p,INJECT=0)
             for f,w,h,p in itertools.product((0,1),(0,1),range(5),(0,1))]
    cases += [dict(FULL=f,ENV16=w,HEAD=4,PRESENT=1,INJECT=1)
              for f,w in itertools.product((0,1),(0,1))]
    root.mkdir()
    save(root/'started.json',dict(pins=pins,cases=cases,invocation=os.environ['INVOCATION_ID'],
        model=str(model),qemu=str(qemu),definitions=sorted(defs),latencies=[0,7],
        x87_trace=False,repaired_rtl=repaired,canonical_oracle_changed=False,standard_suite=False))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(root),PYTHONDONTWRITEBYTECODE='1')

    def sequence(index, case):
        folder = root/('-'.join(k.lower()+str(v) for k,v in case.items())); folder.mkdir()
        cpu = 13 + index%4
        def run(label, command, leaf=None, latency=0):
            actual = ['taskset','-c',str(cpu),'timeout','--kill-after=3s','30s',*map(str,command)]
            save(folder/(label+'.command.json'),actual)
            observed = {}; start = time.monotonic()
            with (folder/(label+'.log')).open('x') as log, (folder/(label+'.stderr.log')).open('x') as err:
                child = subprocess.Popen(actual, env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                    stdout=log,stderr=err,start_new_session=True)
                try:
                    while child.poll() is None:
                        assert time.monotonic()-start < 40
                        queue = [child.pid] if leaf else []
                        while queue:
                            pid = queue.pop()
                            try:
                                p = Path('/proc')/str(pid)
                                queue.extend(map(int,(p/'task'/str(pid)/'children').read_text().split()))
                                if (p/'exe').readlink().name == leaf:
                                    aff = sorted(os.sched_getaffinity(pid)); assert aff == [cpu]
                                    observed[pid] = aff
                            except (FileNotFoundError,ProcessLookupError): pass
                        time.sleep(.001)
                    rc = child.wait()
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid,signal.SIGTERM)
                        try: child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid,signal.SIGKILL); child.wait()
            save(folder/(label+'.native.json'),dict(exit=rc,observed_affinity=observed,
                seconds=time.monotonic()-start,child_reaped=not (Path('/proc')/str(child.pid)).exists()))
            assert not leaf or observed, (label,'actual child not observed')
            return rc
        obj, elf, image = [folder/('fixture.'+s) for s in ('o','elf','bin')]
        assert run('assemble',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
            *[f'-D{k}={v}' for k,v in case.items()],'-c',HERE/'fault.S','-o',obj]) == 0
        assert run('link',['ld','-m','elf_i386','-T',linker,'--build-id=none',obj,'-o',elf]) == 0
        assert run('binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image]) == 0
        assert image.stat().st_size == 65536
        if repaired: assert sha(image)==witness_images[tuple(sorted(case.items()))]
        symbols = {r[2]:int(r[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                   if len(r:=line.split()) == 3 and r[0]!='U'}
        expected = 135 if case['INJECT'] else 133
        q = run('qemu',[qemu,'-L',bios,'-display','none','-monitor','none','-serial','none','-no-reboot',
            '-machine','pc','-cpu','pentium','-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04',
            '-bios',image],qemu.name)
        g = run('golden',[sys.executable,'-B',producer,'--system','--qemu',qemu,'--cpu','pentium',
            '--image',image,'--image-mode','bios','--max-insn','4000','--port',str(43100+index),
            '--out',folder/'golden.vtrace','--args','-L',bios],qemu.name)
        rows=[]
        for latency in (0,7):
            label='rtl-l'+str(latency); tracepath=folder/(label+'.vtrace')
            r=run(label,[model,'--system','--cosim','--cycle-func','--l1-axi','--image',image,
                '--out',tracepath,'--max-insn','4000','--max-cycles','2000000',
                '--quiesce','4096','+ven_faultlog'],model.name,latency)
            d=run(label+'-compare',[sys.executable,'-B',compare,'--mode','func','--all',
                folder/'golden.vtrace',tracepath])
            text=(folder/(label+'.log')).read_text()+(folder/(label+'.stderr.log')).read_text()
            trace=tracefmt.read_trace(str(tracepath))
            faults=re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+)',text,re.M)
            wanted=[('14',f'{2+case["PRESENT"]:08x}',f'{symbols["hot_op"]:08x}')] if case['HEAD'] else []
            success=(r==expected and faults==wanted and trace.sys and not trace.x87 and
                100<len(trace.records)<4000 and int(trace.records[-1]['eax'],16)&255==(0x43 if case['INJECT'] else 0x42))
            paired=int(re.search(r'pairedV=(\d+)',text)[1])
            # The automatic-quiesce message is absent with explicit --quiesce.
            # Require actual cache backing activity, not that optional message.
            backing=re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)',text)
            assert len(backing)==1 and int(backing[0])>0 and paired>0
            rows.append(dict(latency=latency,rtl_exit=r,rtl_self_check=bool(success),compare_exit=d,
                records=len(trace.records),paired_v=paired,backing_acks=int(backing[0]),faults=faults))
        row=dict(case=case,qemu_exit=q,golden_exit=g,rows=rows,image_sha256=sha(image),
            passed=q==expected and g==0 and all(r['rtl_self_check'] and r['compare_exit']==0 for r in rows))
        save(folder/'closed.json',row); print(case,'PASS' if row['passed'] else 'FAIL',flush=True)
        return row
    result=dict(passed=False,rows=[],errors=[],gameplay_ipc=None,standard_suite=False,physical_board=False)
    begin=time.monotonic()
    with ThreadPoolExecutor(max_workers=4) as pool:
        fs={pool.submit(sequence,i,c):c for i,c in enumerate(cases)}
        for f in as_completed(fs):
            try: result['rows'].append(f.result())
            except Exception as e: result['errors'].append(dict(case=fs[f],error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    result['memory_events']=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result['passed']=len(result['rows'])==44 and all(r['passed'] for r in result['rows']) and not result['errors'] and result['pins_unchanged'] and result['memory_events']['oom']==result['memory_events']['oom_kill']=='0'
    result['artifacts']={str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file()}
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__': raise SystemExit(main())
