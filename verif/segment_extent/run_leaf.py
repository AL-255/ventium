"""Prove the arithmetic identity and simulate the exact proposed SV function.

No whole-core acceptance, synthesized timing result or relaxed segment policy.
Two negative functions must fail the same native miter; symbolic counterexamples
also show why zero count and the next-byte-block term cannot be discarded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare as recipe

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','out'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    parent,root=args.parent.resolve(strict=True),args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    original=(parent/recipe.FILE).read_text(); changed=recipe.transform(original)
    assert changed.count(recipe.FUNCTION)==1
    pins={str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),HERE/'tb_extent.sv',
        parent/recipe.FILE,REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN']),Path('/usr/bin/z3'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream: json.dump(value,stream,indent=2)
    def write(path,text):
        with path.open('x') as stream: stream.write(text)
        pins[str(path)]=sha(path)
    source=root/'candidate'/recipe.FILE; source.parent.mkdir(parents=True)
    write(source,changed)
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),affinity=sorted(os.sched_getaffinity(0))))
    begin=time.monotonic(); rows=[]; queries=[]
    result=dict(passed=False,errors=[],whole_core=False,timing_measured=False,hardware_acceptance=False,
                standard_suite=False,gameplay_ipc=None)
    try:
        expressions=[('equivalence','(not (= old new))','unsat'),
            ('zero-count-needed','(and (= count #x00) (not (= old (or (bvugt off bound) tail))))','sat'),
            ('adjacent-block-needed','(and (not (= count #x00)) (not (= ((_ extract 31 8) off) ((_ extract 31 8) bound))) old (not (bvugt off bound)))','sat')]
        for name,expr,expected in expressions:
            path=root/(name+'.smt2'); write(path,recipe.symbolic()+'(assert '+expr+')\n(check-sat)\n')
            native=subprocess.run(['/usr/bin/z3',path],capture_output=True,text=True,timeout=20)
            write(root/(name+'.log'),native.stdout+native.stderr)
            assert native.returncode==0 and not native.stderr and native.stdout.strip()==expected
            queries.append(dict(name=name,result=expected))
        variants=[('positive',recipe.FUNCTION),
            ('zero-underflow-lost',recipe.FUNCTION.replace("(zero_last > {1'b0,bound})","1'b0")),
            ('adjacent-block-lost',recipe.FUNCTION.replace("({1'b0,off[31:8]} + 25'd1 == {1'b0,bound[31:8]})","1'b0"))]
        assert len({text for _,text in variants})==3
        for name,text in variants:
            folder=root/name; folder.mkdir()
            code=folder/'miter.sv'; write(code,(HERE/'tb_extent.sv').read_text().replace('  /* FUNCTION */',text))
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-j','32',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module','tb_extent','--Mdir',folder/'obj','-o','test',code]
            row=dict(name=name,command=list(map(str,command))); rows.append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=120)
            row['build_exit']=native.returncode; assert native.returncode==0
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run([folder/'obj/test'],stdout=stream,stderr=subprocess.STDOUT,timeout=60)
            row['native_exit']=native.returncode; log=(folder/'run.log').read_text()
            if name=='positive': assert native.returncode==0 and 'SEG-EXTENT-OK vectors=2852512' in log
            else: assert native.returncode in (-6,1,134) and 'SEG-EXTENT-MISMATCH' in log
            row['log']=log
            row['artifacts']={str(p):sha(p) for p in (code,folder/'build.log',folder/'run.log',folder/'obj/test')}
        result['passed']=True
    except Exception as error: result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,rows=rows,queries=queries,pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
