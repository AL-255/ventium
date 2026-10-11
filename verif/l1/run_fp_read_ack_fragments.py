#!/usr/bin/env python3
"""Cold unaligned FP page-fault/retry A/B on unchanged UV-fast models.

Each first 32-bit operand read straddles a page. Use actual guest I/O exit,
complete QEMU architectural traces and independent cycle traces; no snapshots,
slow-mode acceptance, altered goldens or forced fragment state.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time
from prepare_fp_fragment_faults import transform
from run_fp_read_ack_faults import cases

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import compare
import tracefmt
import check_faultlog


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)


def expected_faults(case):
    # Unchanged shared prelude: one not-present write and two write-protection
    # checks precede the FP source's read fault. None may be ignored globally.
    result = {(14, 2): 1, (14, 3): 2, (14, 0): 1}
    if case['nm']:
        result[7, 0] = 1
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for flag in ('control', 'candidate', 'out'):
        ap.add_argument('--'+flag, type=Path, required=True)
    ap.add_argument('--workers', type=int, choices=range(1, 33), default=32)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 2*1024**3
    models = dict(control=args.control.resolve(strict=True), candidate=args.candidate.resolve(strict=True))
    pins, profiles = {}, []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defines = set(re.findall(r'\+define\+(\w+)', command))
        assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_FP_LOAD_EARLY_CMD', 'VEN_FP_LOAD64', 'VEN_FP_MEM_ADMIT'} <= defines
        assert ' --assert ' in command and not {'SYNTHESIS', 'VTM_NO_DPI'} & defines
        profiles.append(defines)
        pins.update({str(p):sha(p) for p in (model, stamp)})
    assert profiles[0] == profiles[1]
    helper = Path('/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO/system/run_same_profile_fp.py').resolve(strict=True)
    spec = importlib.util.spec_from_file_location('fp_native_grade', helper)
    grade = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(grade)
    source = REPO/'verif/sys/tests/prepsfetch/prepsfetch.S'
    linker = source.with_suffix('.ld')
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    paths = (Path(__file__), Path(__file__).with_name('prepare_fp_fragment_faults.py'),
             Path(__file__).with_name('run_fp_read_ack_faults.py'), source, linker, qemu,
             helper, REPO/'verif/diff/compare.py', REPO/'verif/diff/tracefmt.py',
             REPO/'verif/qemu-trace/gen_trace.py', REPO/'verif/sys/run-native-system.py',
             REPO/'verif/sys/check_faultlog.py')
    pins.update({str(p):sha(p) for p in paths})
    root.mkdir()
    for delta in (1, 2, 3):
        p = root/('source-d%d.S' % delta)
        with p.open('x') as stream:
            stream.write(transform(source.read_text(), delta))
        pins[str(p)] = sha(p)
    matrix = [(delta, case) for delta in (1, 2, 3) for case in cases()]
    save(root/'started.json', dict(pins=pins, matrix=matrix, workers=args.workers,
         models={k:str(v) for k,v in models.items()}, invocation=os.environ.get('INVOCATION_ID'),
         affinity=sorted(os.sched_getaffinity(0))))
    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_', 'FP_'))}
    env.update(TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1')

    def run(leaf, label, command, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '45s', *map(str,command)]
        save(leaf/(label+'.command.json'), command)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            child = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)))
            affinity = sorted(os.sched_getaffinity(child.pid))
            assert affinity == sorted(os.sched_getaffinity(0))
            status = child.wait()
        save(leaf/(label+'.exit.json'), dict(native_exit=status, affinity=affinity))
        assert status == expected, (label, status, expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()

    def check(item):
        delta, case = item
        leaf = root/('d%d-k%d-n%d-p%d-s%d' % (delta,case['kind'],case['nm'],case['pending'],case['segment']))
        leaf.mkdir()
        defs = ['-DPREP_FP_MEM']
        if case['kind']: defs.append('-DPREP_FP_LOAD=%d' % case['kind'])
        if case['nm']: defs.append('-DPREP_FP_NM=%d' % case['nm'])
        if case['pending']: defs.append('-DPREP_FP_PENDING')
        if case['segment']: defs.append('-DPREP_FP_RELOC' if case['segment']==1 else '-DPREP_FP_SS')
        obj, elf, image = [leaf/('fixture.'+ext) for ext in ('o','elf','bin')]
        run(leaf, 'assemble', ['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie','-Wall',
                             *defs,'-c',root/('source-d%d.S' % delta),'-o',obj])
        run(leaf, 'link', ['gcc','-m32','-nostdlib','-static','-no-pie','-Wl,-T,'+str(linker),
                         '-Wl,--build-id=none','-o',elf,obj])
        run(leaf, 'binary', ['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
        symbols = {p[2]:int(p[0],16) for s in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                   if len(p:=s.split())==3 and p[0]!='U'}
        assert image.stat().st_size==65536 and symbols['fp_source']==0x8013
        pc = symbols['fp_source']
        if case['pending']:
            assert symbols['fp_pending_source']==pc-2
            offset = symbols['fp_source_image']-0xf0000
            assert image.read_bytes()[offset+17:offset+19]==bytes.fromhex('d8f0')
        run(leaf, 'free-qemu', [qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
            '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        run(leaf, 'golden', [sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
            '--system','--x87','--image',image,'--image-mode','bios','--out',leaf/'golden.vtrace',
            '--max-insn','2500','--port',port])
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert gold.sys and gold.x87 and 0<len(gold.records)<2500
        assert int(gold.records[-1]['eax'],0)==0x42 and int(gold.records[-1]['edx'],0)&65535==0xf4
        assert sum(int(r['pc'],0)==pc for r in gold.records)==(3 if case['nm'] else 2)
        measures=[]
        for latency in (0,7):
            both={}
            for name,model in models.items():
                observed={}
                for mode in ('cycle-func','cycle'):
                    label='%s-lat%d-%s' % (name,latency,mode)
                    stdout,stderr=run(leaf,label,[model,'--system','--cosim','--x87','--'+mode,'--l1-axi',
                        '--image',image,'--out',leaf/(label+'.vtrace'),'--max-insn','2500',
                        '--max-cycles','3000000','--quiesce','4096','+ven_faultlog','+ven_fpdirectlog',
                        '+ven_fp_async_log','+ven_fpload64log','+ven_fpload64_pc=00008013'],133,latency)
                    trace=tracefmt.read_trace(str(leaf/(label+'.vtrace')))
                    observed[mode]=trace.records
                    assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),expected_faults(case))
                    faults=list(re.finditer(rf'^\[FAULT\] vec=14 err=00000000 pc={pc:08x}\b',stdout,re.M))
                    commands=list(re.finditer(rf'^\[FPLOADCMD\] ACCEPT .*pc={pc:08x}\b',stdout,re.M))
                    assert len(faults)==len(commands)==1 and commands[0].start()>faults[0].start()
                    assert re.findall(r'^\[FPLOAD64\] complete resident operands=(\d+)$',stdout,re.M)==['0']
                    if case['nm']:
                        nm=list(re.finditer(rf'^\[FAULT\] vec=7 err=00000000 pc={pc:08x}\b',stdout,re.M))
                        assert len(nm)==1 and nm[0].start()<faults[0].start()
                        assert '[FPMEM] ADMIT' not in stdout[:nm[0].start()]
                    if case['pending']:
                        assert re.search(rf'^\[FP-ASYNC-DRAIN\] pc={pc:08x} pending=1 .*walk=1',stdout,re.M)
                    if mode=='cycle-func':
                        grade.grade_fp_native(trace,stdout,stderr,133,133,2500)
                        log=io.StringIO()
                        status=compare.compare_func(gold,trace,False,0xffffffff,False,20,log,sys_both=True)
                        with (leaf/(label+'-diff.log')).open('x') as stream: stream.write(log.getvalue())
                        assert status==0,log.getvalue()
                    else:
                        assert trace.mode=='cycle' and not grade.native.FATAL.search(stdout+stderr)
                both[name]=observed
                measures.append(dict(delta=delta,case=case,model=name,latency=latency,
                    records=len(observed['cycle-func']),last_retire_clock=observed['cycle'][-1]['cyc'],
                    paired_v=sum(r.get('pipe')=='V' and r.get('paired') for r in observed['cycle'])))
            assert both['control']==both['candidate'],('complete A/B difference',delta,case,latency)
        save(leaf/'closed.json',dict(passed=True,measurements=measures,image_sha256=sha(image)))
        return measures

    result=dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False,
                reset_sweep=False,physical_board=False)
    begin=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs={pool.submit(check,item):item for item in matrix}
        for job in concurrent.futures.as_completed(jobs):
            try: result['measurements'].extend(job.result())
            except Exception as error: result['errors'].append(dict(case=jobs[job],error=repr(error)))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed']=not result['errors'] and len(result['measurements'])==192 and result['pins_unchanged']
    result['candidate_paired_v']=sum(r['paired_v'] for r in result['measurements'] if r['model']=='candidate')
    result['passed'] &= result['candidate_paired_v']>0
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
