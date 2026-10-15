"""Diagnose exact tiny-result handling with existing native/QEMU/shared-FPU binaries.

No compilation, source mutation or reference promotion. Record expected bad
implementations separately from successful execution of the diagnostic.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import resource
import shutil
import struct
import subprocess
import time
import traceback

from run_small_quotient import sha,save
import state_vectors
import underflow_vectors as vectors

REPO=Path(__file__).resolve().parents[3]
SCRATCH=Path('/home/yukidama/external/tmp').resolve(strict=True)
EVIDENCE=SCRATCH/'ventium-fprem-sequence.iSZ9BAj4'


def execute(label,command,root,stdin=None):
    before=time.monotonic();seen=set()
    with (root/(label+'.out')).open('xb') as out,(root/(label+'.err')).open('xb') as err, \
            (stdin or Path('/dev/null')).open('rb') as inp:
        child=subprocess.Popen(command,stdin=inp,stdout=out,stderr=err)
        observed=[]
        try:
            while child.poll() is None:
                try:
                    proc=Path('/proc')/str(child.pid)
                    if proc.joinpath('exe').resolve()==Path(command[0]).resolve():
                        seen.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        if not observed:
                            observed.append(dict(exe=str(proc.joinpath('exe').resolve()),
                                argv=proc.joinpath('cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                                cgroup=proc.joinpath('cgroup').read_text(),
                                starttime=proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]))
                except (FileNotFoundError,ProcessLookupError):pass
                assert time.monotonic()-before<60,label+' timeout'
                time.sleep(.0001)
            rc=child.wait()
        finally:
            if child.poll() is None:child.kill()
            child.wait()
    result=dict(label=label,command=list(map(str,command)),native_exit=rc,pid=child.pid,
        actual_wait=True,reaped=not Path('/proc',str(child.pid)).exists(),affinity=sorted(seen),
        observed=observed,seconds=time.monotonic()-before,stdout_sha256=sha(root/(label+'.out')))
    save(root/(label+'-native.json'),result)
    assert rc==0 and result['reaped'] and seen=={(12,)} and observed
    assert observed[0]['argv']==list(map(str,command))
    assert observed[0]['cgroup'].strip().endswith('/'+os.environ['UNDERFLOW_OWNER'])
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    root=ap.parse_args().out.resolve()
    assert __debug__ and root.is_relative_to(SCRATCH) and root!=SCRATCH and not root.exists()
    assert os.environ['INVOCATION_ID'] and Path(os.environ['TMPDIR']).resolve()==SCRATCH
    assert os.sched_getaffinity(0)=={12} and SCRATCH.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(SCRATCH).free>4*1024**3+32*1024**2
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    probe=EVIDENCE/'exception-state-r2/probe'
    qemu=EVIDENCE/'build-exceptions-r1/build/qemu-i386'
    leaf=EVIDENCE/'srt-exceptions-r3';model=leaf/'candidate/obj/test'
    assert sha(probe)=='d380fe69cd85c632abe444e0adcc098ce9adaef47a79a554dffde9de438a3bd3'
    assert sha(qemu)=='b81831c8976043f8d8d6fc7eeb1d1a981337ca274848f2fcc32b2d3fffbf8e48'
    assert sha(model)=='b8b49226de20f1ec0bdf263865909b80d3dd761137d2977fe55e5f868621e8d0'
    started=json.loads((leaf/'started.json').read_text());closed=json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    candidate=next(r for r in closed['variants'] if r['name']=='candidate')
    assert candidate['mismatches']==0
    pins=dict(started['pins']);pins.update(candidate['artifacts'])
    source=leaf/'candidate/source'
    hardware=SCRATCH/'ventium-data-size.v2HaTO2X/fetch-metadata-fpga-r1/ventium'
    for name in ('fp_shared/ven_fp_top.sv','rtl/fpu/fpu_srt_div.sv'):
        assert sha(source/name)==sha(hardware/name)
        pins[str(hardware/name)]=sha(hardware/name)
    for p in (Path(__file__),Path(vectors.__file__),Path(vectors.oracle.__file__),Path(state_vectors.__file__),
              Path(__file__).with_name('state_probe.c'),Path(__file__).with_name('run_small_quotient.py'),
              probe,qemu,model,leaf/'started.json',leaf/'closed.json',
              REPO/'ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf'):
        pins[str(p.resolve())]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    rows=vectors.rows();root.mkdir();save(root/'cases.json',rows)
    (root/'stdin.bin').write_bytes(b''.join(map(state_vectors.pack,rows)))
    with (root/'vectors.txt').open('x') as f:
        for r in rows:
            f.write(f"{r['cw']:04x} {r['sw']:04x} {r['tag']:04x} {r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x} {r['op']}\n")
    save(root/'started.json',dict(pins=pins,cases=len(rows),invocation=os.environ['INVOCATION_ID'],
        owner=os.environ['UNDERFLOW_OWNER'],scope='single shared-FPU instruction, not CPU or system delivery',
        compiler_launched=False,definitions=started['definitions']))
    result=dict(diagnostic_completed=False,errors=[],executions=[],implementations={},
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    try:
        outputs={}
        for label,command,inp in (
            ('native',[probe],root/'stdin.bin'),('qemu',[qemu,'-cpu','pentium',probe],root/'stdin.bin'),
            ('rtl',[model,'+vectors='+str(root/'vectors.txt')],None)):
            result['executions'].append(execute(label,command,root,inp))
            raw=(root/(label+'.out')).read_bytes()
            if label=='rtl':
                text=raw.decode();found=re.findall(r'^ROW (\d+) ([0-9a-f]{216}) (\d+) (\d+)$',text,re.M)
                assert f'REM-EXCEPTION-TRANSPORT-OK rows={len(rows)} resets=3' in text and len(found)==len(rows)
                assert [int(r[0]) for r in found]==list(range(len(rows)))
                assert all(r[3]=='0' for r in found)
                outputs[label]=[int(r[1],16).to_bytes(108,'little') for r in found]
            else:
                assert len(raw)==len(rows)*108
                outputs[label]=[raw[i:i+108] for i in range(0,len(raw),108)]
        for label,data in outputs.items():
            failures=[];groups=Counter();conditions=Counter()
            for i,(r,raw) in enumerate(zip(rows,data)):
                errors=vectors.check(r,raw);expect=vectors.expected(r)
                sw=struct.unpack_from('<I',raw,4)[0]&0xffff
                if expect['underflow']:conditions[hex(sw&0x4700)]+=1
                if errors:
                    failures.append(dict(index=i,label=r['label'],errors=errors,
                        expected=expect,actual_sw=sw,actual_st0=raw[28:38].hex()))
                    groups[('underflow' if expect['underflow'] else 'operand_abort' if expect['operand_abort'] else 'control')]+=1
            save(root/(label+'-graded.json'),dict(failures=failures,underflow_condition_counts=dict(conditions)))
            result['implementations'][label]=dict(passed=not failures,cases=len(rows),failures=len(failures),
                failure_groups=dict(groups),underflow_condition_counts=dict(conditions))
        result['diagnostic_completed']=True
    except Exception as e:result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['diagnostic_completed'] &= result['pins_unchanged']
    save(root/'closed.json',result);print(json.dumps(result,indent=2),flush=True)
    return int(not result['diagnostic_completed'])


if __name__=='__main__':raise SystemExit(main())
