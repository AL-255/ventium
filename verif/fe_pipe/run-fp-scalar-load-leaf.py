#!/usr/bin/env python3
"""Actual final-operand handoff and payload, default and opt-in predicates."""
import argparse,hashlib,json,os,re,resource,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,close_fds=False)
    args.out.mkdir()
    source=args.source.resolve(strict=True)/'rtl/core'
    paths=(Path(__file__),source/'core.sv',source/'ventium_decode_pkg.sv',HERE/'tb_fp_scalar_load_cmd.sv')
    pins={str(p):sha(p) for p in paths}
    text=(source/'core.sv').read_text()
    start='  assign fp_shared_load_cmd = cycle_mode && (state == S_FLOAD) &&'
    end='`else\n  assign fp_shared_load_cmd = 1\'b0;'
    assert text.count(start)==text.count(end)==1
    body=text.split(start)[1].split(end)[0]
    assert body.count('VEN_FP_SCALAR_LOAD_CMD')==1 and body.count('assign fp_shared_cmd_mem')==1
    generated=args.out/'scalar_load_assignments.svh'
    with generated.open('x') as f:f.write(start+body)
    pins[str(generated)]=sha(generated)
    negative=args.out/'negative-include';negative.mkdir()
    neg_body=(start+body).replace('`ifdef VEN_FP_SCALAR_LOAD_CMD','`ifdef NEGATIVE_DISABLED_SCALAR_CMD')
    assert neg_body != start+body
    with (negative/generated.name).open('x') as f:f.write(neg_body)
    pins[str(negative/generated.name)]=sha(negative/generated.name)
    save(args.out/'inputs.json',pins)
    rows=[]
    for name,enabled in (('disabled',False),('enabled',True),('negative',True)):
        obj=args.out/name
        command=['/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert','-j','32',
            '-Wall','-Wno-UNUSED','-Wno-fatal',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '--top-module','tb_fp_scalar_load_cmd','-I'+str(negative if name=='negative' else args.out),'--Mdir',str(obj),'-o','tb_scalar',
            '+define+VEN_FP_LOAD64',*(['+define+VEN_FP_SCALAR_LOAD_CMD'] if enabled else []),
            str(source/'ventium_decode_pkg.sv'),str(HERE/'tb_fp_scalar_load_cmd.sv')]
        save(args.out/(name+'-build.command.json'),command)
        with (args.out/(name+'-build.log')).open('x') as log:
            result=subprocess.run(command,env=dict(os.environ,TMPDIR=str(args.out)),stdout=log,stderr=subprocess.STDOUT,timeout=120)
        save(args.out/(name+'-build.exit.json'),dict(exit=result.returncode));assert result.returncode==0
        with (args.out/(name+'-run.log')).open('x') as log:
            result=subprocess.run([obj/'tb_scalar'],stdout=log,stderr=subprocess.STDOUT,timeout=15)
        save(args.out/(name+'-run.exit.json'),dict(exit=result.returncode))
        if name=='negative':
            # This pinned Verilator runtime exits 1 on an assertion fatal.
            assert result.returncode == 1 and 'scalar final operand op=30 bytes=4 step=0 ack=1 cw=037f sw=0000' in (args.out/(name+'-run.log')).read_text()
            rows.append(dict(name=name,rejected=True,native_exit=result.returncode,binary_sha256=sha(obj/'tb_scalar')))
            continue
        assert result.returncode==0
        counts=re.findall(r'SCALAR-LOAD-CMD-LEAF-OK checks=(\d+)',(args.out/(name+'-run.log')).read_text())
        assert counts==['114688'],counts
        rows.append(dict(name=name,checks=int(counts[0]),binary_sha256=sha(obj/'tb_scalar')))
    assert all(sha(Path(p))==h for p,h in pins.items())
    result=dict(passed=True,variants=rows,inputs_unchanged=True,gameplay_ipc=None,standard_suite=False)
    save(args.out/'closed.json',result);print(json.dumps(result),flush=True)
if __name__=='__main__':main()
