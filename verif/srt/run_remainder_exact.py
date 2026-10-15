"""Actual shared-SRT finite sequence tests against an integer-only oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

import prepare_remainder_exact as patch
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/qemu-trace/remainder_sequence'))
import oracle


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2)


def cases():
    rows=oracle.cases()
    # Valid subnormal operands, ties/neighbours, and a normal/subnormal pair.
    # DE delivery, NaNs, unsupported encodings and empty-stack handling are
    # top-level concerns, not assertions about this arithmetic engine's ports.
    pairs=[((0,3),(0,2)),((0,2),(0,3)),((0,1),(0,2)),((0,1),(0,3)),
           ((0,(1<<63)-1),(0,(1<<62)+1)),((1,1<<63),(0,(1<<63)-1)),
           ((0,(1<<63)-1),(1,1<<63)),((0x3fff,1<<63),(0,3)),
           ((0x3fff,0xc000000000000000),(0x4000,1<<63)),
           ((0x3fff,(1<<63)+1),(0x4000,1<<63))]
    for kind in (0,1):
        for pc in (0,2,3):
            for rc in range(4):
                for a,b in pairs:
                    for sa,sb in ((0,0),(0,1),(1,0),(1,1)):
                        rows.append(dict(id=len(rows),kind=kind,cw=0x7f|(pc<<8)|(rc<<10),sw=0x3000,
                            a=(a[0]|(sa<<15),a[1]),b=(b[0]|(sb<<15),b[1])))
    return rows


def grade(rows,path,allow_incomplete=False):
    errors=[];steps={};previous={};finished=set();partial=0;latencies={};records=0;last_ident=-1
    with path.open() as f:
        for line in f:
            fields=line.split();assert len(fields)==9
            ident,step=map(int,fields[:2]);number,q,c2,ie,exceptions,rounded=map(lambda s:int(s,16),fields[2:8])
            cycles=int(fields[8]);assert 0<=ident<len(rows) and step==steps.get(ident,0) and ident not in finished
            assert ident>=last_ident
            last_ident=ident
            steps[ident]=step+1;records+=1;row=rows[ident]
            value=(number>>64,number&((1<<64)-1));incoming=previous.get(ident,row['a'])
            assert q<8 and c2<2 and ie<2 and exceptions<8 and rounded<2
            status=oracle.quotient_bits(q)|(c2<<10)|ie|((exceptions&1)<<5)|((exceptions&2)<<3)|((exceptions&4)<<1)
            reasons=oracle.step_errors(incoming,row['b'],value,status,row['kind']==1)
            if rounded:reasons.append('unrelated_divide_rounding_output')
            if c2:partial+=1
            else:
                finished.add(ident)
                ai,bi,ri=oracle.aligned(row['a'],row['b'],value)
                expected,quotient=oracle.final(ai,bi,row['kind']==1)
                if ri!=expected:reasons.append('wrong_total_remainder')
                if q!=quotient&7:reasons.append('wrong_total_quotient')
            if reasons:errors.append(dict(id=ident,step=step,reasons=reasons,incoming=incoming,result=value,status=status))
            previous[ident]=value;latencies[cycles]=latencies.get(cycles,0)+1
    complete=set(steps)==finished==set(range(len(rows)))
    assert complete or allow_incomplete
    return dict(passed=not errors and complete,cases=len(rows),observed_cases=len(steps),
                completed_cases=len(finished),all_sequences_complete=complete,records=records,partial_steps=partial,
                max_steps=max(steps.values()),latencies=latencies,errors=errors)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();parent=args.parent.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.environ['INVOCATION_ID']
    assert os.sched_getaffinity(0)==set(range(8,16)) and shutil.disk_usage(scratch).free>5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
        'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    dut=parent/'rtl/fpu/fpu_srt_div.sv';pkg=parent/'rtl/fpu/fpu_x87_pkg.sv'
    before=dut.read_text();after=patch.transform(before);tb=Path(__file__).with_name('tb_remainder_exact.sv')
    pins={str(p):sha(p) for p in (dut,pkg,tb,Path(__file__),Path(patch.__file__),Path(oracle.__file__),
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',Path('/tools/verilator/v5.046/bin/verilator'))}
    root.mkdir();rows=cases();save(root/'cases.json',rows)
    (root/'vectors.txt').write_text(''.join(f"{r['id']} {r['kind']} {(r['cw']>>8)&3} {(r['cw']>>10)&3} "
        f"{r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x}\n" for r in rows))
    pins[str(root/'vectors.txt')]=sha(root/'vectors.txt')
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],source_sha256=sha(dut),
        candidate_sha256=hashlib.sha256(after.encode()).hexdigest(),cases=len(rows),finite_arithmetic_only=True))
    results=[];start=time.monotonic();errors=[]
    try:
        for name,source,split in (('control',before,True),('candidate',after,True),('unsplit',after,False)):
            dest=root/name;dest.mkdir();(dest/'fpu_srt_div.sv').write_text(source)
            cmd=[str(REPO/'tools/verilator_serial.sh'),'-j','32','--binary','--timing','--assert','--threads','1',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '+define+VEN_FPREM',*(['+define+VEN_SRT_REM_OPERAND_SPLIT'] if split else []),
                '--Mdir',str(dest/'obj'),'--top-module','tb_remainder_exact',str(pkg),str(dest/'fpu_srt_div.sv'),str(tb)]
            with (dest/'build.log').open('x') as f:
                built=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=150,pass_fds=(9,))
            save(dest/'build.json',dict(command=cmd,native_exit=built.returncode));assert built.returncode==0
            binary=dest/'obj/Vtb_remainder_exact'
            cmd=['taskset','-c','12',str(binary),'+input='+str(root/'vectors.txt'),'+output='+str(dest/'records.txt')]
            with (dest/'run.log').open('x') as f:
                child=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);observed=set();begin=time.monotonic()
                try:
                    while child.poll() is None:
                        try:
                            # taskset briefly starts with its owner's affinity.
                            # Qualify the actual native simulator, not that helper.
                            if (Path('/proc')/str(child.pid)/'exe').resolve().name==binary.name:
                                observed.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        except ProcessLookupError:pass
                        assert time.monotonic()-begin<120
                        time.sleep(.001)
                    code=child.wait()
                finally:
                    if child.poll() is None:child.kill()
                    child.wait()
            save(dest/'run.json',dict(command=cmd,native_exit=code,actual_wait=True,reaped=True,
                observed_affinity=sorted(observed),binary_sha256=sha(binary),record_sha256=sha(dest/'records.txt')))
            assert observed=={(12,)}
            incomplete_control=name=='control' and code==1 and 'partial loop did not terminate' in (dest/'run.log').read_text()
            assert code==0 or incomplete_control
            checked=grade(rows,dest/'records.txt',allow_incomplete=incomplete_control)
            checked.update(native_exit=code,bounded_noncompletion_observed=incomplete_control)
            save(dest/'graded.json',checked)
            results.append(dict(name=name,**{k:v for k,v in checked.items() if k!='errors'},mismatches=len(checked['errors'])))
            print(json.dumps(results[-1]),flush=True)
    except Exception as error:errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    passed=stable and not errors and len(results)==3 and not results[0]['passed'] and all(r['passed'] for r in results[1:])
    result=dict(passed=passed,pins_unchanged=stable,results=results,errors=errors,seconds=time.monotonic()-start,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result,indent=2),flush=True)
    return int(not passed)


if __name__=='__main__':raise SystemExit(main())
