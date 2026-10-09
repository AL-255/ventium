#!/usr/bin/env python3
"""Actual scalar dispatch admission include, enabled and disabled."""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    source=args.source.resolve(strict=True)/'rtl/core'
    pins={str(p):sha(p) for p in (Path(__file__),HERE/'tb_fp_scalar_dispatch.sv',
          source/'core_fp_scalar_dispatch.svh',source/'ventium_decode_pkg.sv',REPO/'tools/build_scope.sh')}
    def save(name,value):
        with (args.out/name).open('x') as f:json.dump(value,f,indent=2)
    def run(command,name,timeout):
        save(name+'.command.json',list(map(str,command)))
        with (args.out/(name+'.log')).open('x') as f:
            proc=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                env=dict(os.environ,TMPDIR=str(args.out)),timeout=timeout)
        save(name+'.exit.json',dict(exit=proc.returncode))
        assert proc.returncode==0,(name,proc.returncode)
    save('inputs.json',pins)
    result=dict(passed=False,variants=[],gameplay_ipc=None,standard_suite=False)
    try:
        for enabled in (False,True):
            name='enabled' if enabled else 'disabled';obj=args.out/('obj-'+name)
            flags=['+define+VEN_FP_SCALAR_DISPATCH'] if enabled else []
            run([REPO/'tools/build_scope.sh','--','taskset','-c','2,3,18,19',
                '/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert','-j','4',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module','tb_fp_scalar_dispatch','-I'+str(source),'--Mdir',obj,'-o','tb_scalar',
                '+define+VEN_FP_SHARED','+define+VEN_FP_SHORT_WINDOW',*flags,
                source/'ventium_decode_pkg.sv',HERE/'tb_fp_scalar_dispatch.sv'],name+'-build',120)
            run([obj/'tb_scalar'],name+'-run',15)
            m=re.findall(r'FP-SCALAR-DISPATCH-LEAF-OK checks=(\d+)',(args.out/(name+'-run.log')).read_text())
            assert m==['66688'],m
            result['variants'].append(dict(name=name,checks=int(m[0]),binary_sha256=sha(obj/'tb_scalar')))
        result['passed']=True
    finally:
        result['inputs_unchanged']=all(sha(Path(p))==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged'];save('closed.json',result)
    print(json.dumps(result),flush=True);assert result['passed']
if __name__=='__main__':main()
