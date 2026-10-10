#!/usr/bin/env python3
"""Cold full-core x87 #NM and architectural-debug A/B with native QEMU checks.

The #NM image deliberately selects only the TS/EM cases from the strict-MF
fixture: the deployed profile does not enable VEN_X87_MF_STRICT. No claim about
the omitted strict-MF cases is made. Leaf tests separately exercise that flag.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import compare
import tracefmt
import check_faultlog
spec = importlib.util.spec_from_file_location('payload', HERE/'run-fp-payload-ab.py')
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for flag in ('control', 'candidate', 'out'):
        ap.add_argument('--'+flag, type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    root.mkdir()
    source = REPO/'verif/sys/tests/px87stk'
    original = (source/'px87trap.S').read_text()
    begin = original.index('    /* ---------------- 3. strict pending #MF')
    end = original.index('/* ============================ handlers')
    selected = original[:begin] + '''    CHKL NMCNT, 2, 0x40
    CHKL MFCNT, 0, 0x41
    CHKL CASES, 2, 0x43
    movl $0x42,%edi
    movl $0x600D600D,%edx
    jmp fail_exit

''' + original[end:]
    nm = root/'nm-ts-em-only.S'
    with nm.open('x') as f:
        f.write(selected)
    models = dict(control=args.control.resolve(strict=True), candidate=args.candidate.resolve(strict=True))
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins = {str(p): sha(p) for p in (Path(__file__), source/'px87trap.S', source/'px87debug.S',
        source/'px87stk.ld', nm, qemu, HERE/'run-fp-payload-ab.py', REPO/'verif/diff/compare.py',
        REPO/'verif/diff/tracefmt.py', REPO/'verif/qemu-trace/gen_trace.py', *models.values())}
    profiles = []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        pins[str(stamp)] = sha(stamp)
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command and {'VEN_L1_AXI','VEN_SYS_FASTPATH_RELOC','VEN_FP_SHARED_DIRECT'} <= defs
        assert 'VEN_X87_MF_STRICT' not in defs
        profiles.append(defs)
    assert profiles[0] == profiles[1]
    def save(path, value):
        with path.open('x') as f:
            json.dump(value, f, indent=2)
    save(root/'started.json', dict(pins=pins, models={k:str(v) for k,v in models.items()}, invocation=os.environ.get('INVOCATION_ID')))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1')
    def run(leaf, label, command, expected=0, latency=0):
        command = ['timeout','--kill-after=3s','60s',*map(str,command)]
        save(leaf/(label+'.command.json'), command)
        with (leaf/(label+'.stdout')).open('x') as out, (leaf/(label+'.stderr')).open('x') as err:
            p = subprocess.run(command, env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)), stdout=out, stderr=err)
        save(leaf/(label+'.exit.json'), dict(native_exit=p.returncode))
        assert p.returncode == expected, (label,p.returncode,expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()
    rows = []
    result = dict(passed=False, errors=[], rows=rows, standard_suite=False, gameplay_ipc=None)
    start = time.monotonic()
    try:
        for label, assembly, x87 in (('nm-ts-em',nm,True),('debug',source/'px87debug.S',False)):
            leaf = root/label
            leaf.mkdir()
            obj, elf, image = [leaf/('fixture.'+s) for s in ('o','elf','bin')]
            run(leaf,'assemble',['as','--32',assembly,'-o',obj])
            run(leaf,'link',['ld','-m','elf_i386','-T',source/'px87stk.ld',obj,'-o',elf])
            run(leaf,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
            assert image.stat().st_size == 65536
            run(leaf,'qemu-free',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
                '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
            extra = ['--x87'] if x87 else []
            run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
                '--system',*extra,'--image',image,'--image-mode','bios','--out',leaf/'golden.vtrace',
                '--max-insn','6000','--port',str(port)])
            gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
            assert 1500 < len(gold.records) < 6000 and int(gold.records[-1]['edi'],0) == 0x42
            if label == 'debug':
                assert int(gold.records[-1]['ebx'],0)==4 and int(gold.records[-1]['ecx'],0)==1
            for latency in (0,7):
                observations = {}
                for name, model in models.items():
                    streams = {}
                    clocks = []
                    for mode in ('cycle-func','cycle'):
                        stem = f'{name}-{latency}-{mode}'
                        out, err = run(leaf,stem,[model,'--system','--cosim',*extra,'--'+mode,'--l1-axi',
                            '--image',image,'--out',leaf/(stem+'.vtrace'),'--max-insn','6000',
                            '--max-cycles','2000000','--quiesce','10000','+ven_faultlog'],133,latency)
                        trace = tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                        assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                        if mode == 'cycle-func':
                            if x87: graded = payload.grade_fp_native(trace,out,err,133,133,6000)
                            else: graded = payload.native.grade_native(trace,out,err,133,133,6000)
                            with (leaf/(stem+'-diff.log')).open('x') as f:
                                assert compare.compare_func(gold,trace,x87,0xffffffff,False,20,f,sys_both=True)==0
                        if label == 'nm-ts-em':
                            check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()),{(7,0):2})
                        footer = re.findall(r'after (\d+) retired in (\d+) clocks',err)
                        assert len(footer)==1 and int(footer[0][0])==len(gold.records)
                        clocks.append(int(footer[0][1])); streams[mode]=trace.records
                    assert clocks[0]==clocks[1]
                    observations[name]=streams
                    rows.append(dict(case=label,model=name,latency=latency,clocks=clocks[0],records=len(gold.records)))
                assert observations['control']==observations['candidate'], 'complete state or cycle A/B mismatch'
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(Path(p))==h for p,h in pins.items()),seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged']
        save(root/'closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
