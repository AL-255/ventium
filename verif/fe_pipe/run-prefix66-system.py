#!/usr/bin/env python3
"""Cold protected-client PREFIX66 A/B with complete QEMU state and real U/V."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import check_faultlog
import compare
import tracefmt
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control', type=Path, required=True)
    ap.add_argument('--candidate', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--offset', action='append', type=int)
    ap.add_argument('--workers', type=int, choices=range(1, 5), default=2)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch) and shutil.disk_usage(scratch).free > 1024**3
    offsets = sorted(set(args.offset if args.offset is not None else range(32)))
    assert offsets and all(0 <= x < 32 for x in offsets)
    args.out.mkdir()
    models = {'control': args.control.resolve(strict=True)}
    if args.candidate:
        models['candidate'] = args.candidate.resolve(strict=True)
    pins, profiles = {}, {}
    for name, model in models.items():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_P54_PREFIX66_REG', 'VEN_SYS_FASTPATH',
                'VEN_SYS_FASTPATH_RELOC', 'VEN_SEG_ENFORCE', 'VEN_FE_PIPE'} <= defs
        assert not {'VEN_SYS_FASTPATH_ALL', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_UOPCACHE'} & defs
        profiles[name] = defs
        for p in (model, stamp): pins[str(p)] = sha(p)
    assert 'VEN_P54_PREFIX66_SYSTEM' not in profiles['control']
    if args.candidate:
        assert profiles['candidate'] == profiles['control'] | {'VEN_P54_PREFIX66_SYSTEM'}
    source, linker = HERE/'prefix66-system.S', REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/run-native-system.py', REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out/'started.json', dict(pins=pins, offsets=offsets,
        models={k:str(v) for k,v in models.items()}, invocation=os.environ.get('INVOCATION_ID')))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(leaf, name, command, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '45s', *map(str, command)]
        save(leaf/(name+'.command.json'), command)
        with (leaf/(name+'.stdout')).open('x') as out, (leaf/(name+'.stderr')).open('x') as err:
            p = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                               stdout=out, stderr=err)
        save(leaf/(name+'.exit.json'), dict(native_exit=p.returncode))
        assert p.returncode == expected, (leaf.name, name, p.returncode, expected)
        return (leaf/(name+'.stdout')).read_text(), (leaf/(name+'.stderr')).read_text()

    def check(case):
        kind, reloc, offset = case
        leaf = args.out/f'k{kind}-r{reloc}-o{offset}'; leaf.mkdir()
        obj, elf, image = [leaf/('fixture.'+x) for x in ('o', 'elf', 'bin')]
        run(leaf, 'assemble', ['gcc', '-m32', '-nostdlib', '-ffreestanding', '-fno-pie', '-fno-pic',
            f'-DKIND={kind}', f'-DRELOC={reloc}', f'-DOFFSET={offset}', '-c', source, '-o', obj])
        run(leaf, 'link', ['gcc', '-m32', '-static', '-no-pie', '-nostdlib',
            '-Wl,-T,'+str(linker), '-Wl,--build-id=none', obj, '-o', elf])
        run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                   if len(p:=line.split())==3 and p[0]!='U'}
        assert image.stat().st_size == 65536 and symbols['hot_u'] % 32 == offset
        assert image.read_bytes()[symbols['hot_u']-0xf0000] == 0x66
        run(leaf, 'free-qemu', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
            '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
            '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], 133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        golden_path = leaf/'golden.vtrace'
        run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
            '--system','--image',image,'--image-mode','bios','--cpu','pentium',
            '--out',golden_path,'--max-insn','1000','--port',str(port)])
        gold = tracefmt.read_trace(str(golden_path))
        assert gold.mode=='func' and gold.sys and 100<len(gold.records)<1000
        assert int(gold.records[-1]['eax'],0)&255 == 0x42
        assert all(all(k in row for k in tracefmt.SYS_CR) for row in gold.records)
        measures=[]
        for latency in (0,7):
            for name,model in models.items():
                traces,stops={},{}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}';path=leaf/(stem+'.vtrace')
                    out,err=run(leaf,stem,[model,'--system','--cosim','--'+mode,'--l1-axi',
                        '--image',image,'--out',path,'--max-insn','1000','--max-cycles','1000000',
                        '--quiesce','4096','+ven_faultlog'],133,latency)
                    trace=tracefmt.read_trace(str(path));traces[mode]=trace.records
                    assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()),{})
                    assert not native.FATAL.search(out) and not native.FATAL.search(err)
                    footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                        r'after (\d+) retired in (\d+) clocks$',err,re.M)
                    assert len(footer)==1 and int(footer[0][0])==len(trace.records)
                    stops[mode]=int(footer[0][1])
                    if mode=='cycle-func':
                        native.grade_native(trace,out,err,133,133,1000)
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,
                                                        log,sys_both=True)==0,(case,stem,'QEMU diff')
                assert stops['cycle']==stops['cycle-func']
                rows=traces['cycle'];hits=[i for i,r in enumerate(rows) if int(r['pc'],0)==symbols['hot_u']]
                assert len(hits)==16
                paired=sum(rows[i+1].get('pipe')=='V' and rows[i+1].get('paired') and
                           rows[i+1]['cyc']==rows[i]['cyc'] for i in hits)
                assert all(int(rows[i+1]['pc'],0)==symbols['hot_v'] for i in hits)
                if name=='control' or kind>=3: assert paired==0,(case,name,'illegal pair',paired)
                if name=='candidate' and kind<=2 and offset<=20:
                    assert paired>0,(case,'eligible prefix never paired')
                if kind<=5:
                    assert min(rows[i]['cyc']-rows[i-1]['cyc'] for i in hits[2:])>=2,'unpaid D1'
                measures.append(dict(case=case,model=name,latency=latency,paired_v=paired,
                    clocks=stops['cycle'],records=len(rows),
                    warm_clocks=rows[hits[-1]]['cyc']-rows[hits[2]]['cyc']))
        if args.candidate:
            for latency in (0,7):
                a,b=[r for r in measures if r['latency']==latency]
                assert b['warm_clocks']<=a['warm_clocks'],(case,latency,'warm regression',a,b)
                if kind>=6: assert b['warm_clocks']==a['warm_clocks'],'fallback changed'
        save(leaf/'closed.json',dict(passed=True,measurements=measures,image_sha256=sha(image)))
        return measures

    cases=[(k,r,o) for k in range(8) for r in (0,1) for o in offsets]
    result=dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False)
    start=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures={pool.submit(check,c):c for c in cases}
        for future in concurrent.futures.as_completed(futures):
            try: result['measurements'].extend(future.result())
            except Exception as exc: result['errors'].append(dict(case=futures[future],error=repr(exc)))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start,
                  all_children_reaped=True)
    result['passed']=not result['errors'] and result['pins_unchanged'] and \
        len(result['measurements'])==len(cases)*len(models)*2
    save(args.out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
