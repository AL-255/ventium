#!/usr/bin/env python3
"""Test source-pinned quotient initialization against both actual SRT engines."""
import argparse,hashlib,json,os,resource,shutil,subprocess,time
from pathlib import Path
from prepare_qacc_init_payload import transform

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    parent=args.parent.resolve(strict=True);out=args.out.resolve()
    repo=Path(__file__).resolve().parents[2]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([str(repo/'tools/build_scope.sh'),'--is-active'],pass_fds=(9,),check=True)
    old=parent/'candidate/rtl/fpu/fpu_srt_div.sv'
    package=old.with_name('fpu_x87_pkg.sv')
    source=old.read_text();changed=transform(source)
    assert source.count('module fpu_srt_div\n')==1
    closed=json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    out.mkdir()
    control=out/'fpu_srt_div_control.sv';new=out/'fpu_srt_div.sv'
    with control.open('x') as f:f.write(source.replace('module fpu_srt_div\n','module fpu_srt_div_control\n'))
    with new.open('x') as f:f.write(changed)
    tb=Path(__file__).with_name('tb_qacc_init_miter.sv')
    recipe=Path(__file__).with_name('prepare_qacc_init_payload.py')
    test=Path(__file__).with_name('test_qacc_init_payload.py')
    pins={str(p):sha(p) for p in (old,package,control,new,tb,recipe,test,Path(__file__),
        parent/'build-closed.json',repo/'tools/build_scope.sh',repo/'tools/verilator_serial.sh',
        Path('/tools/verilator/v5.046/bin/verilator'),Path('/tools/verilator/v5.046/bin/verilator_bin'))}
    def save(n,v):
        with (out/n).open('x') as f:json.dump(v,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))
    result=dict(passed=False,whole_core=False,numeric_oracle=False,gameplay_ipc=None,timing_mhz=None)
    begin=time.monotonic();runs=[]
    try:
        env=dict(os.environ,SRT_QACC_PARENT=str(old),PYTHONDONTWRITEBYTECODE='1')
        with (out/'recipe.log').open('x') as f:
            check=subprocess.run(['python3','-B',str(test)],stdout=f,stderr=subprocess.STDOUT,env=env,timeout=15)
        assert check.returncode==0
        for label,sourcefile in [('candidate',new),('negative-busy-clear',out/'negative/fpu_srt_div.sv')]:
            work=out/label;work.mkdir()
            if label.startswith('negative'):
                sourcefile.parent.mkdir()
                anchor="      endcase\n    end\n  end\nendmodule"
                assert changed.count(anchor)==1
                mutant=changed.replace(anchor,"      endcase\n      if (st != ST_IDLE) qacc <= 128'sd0;\n    end\n  end\nendmodule")
                with sourcefile.open('x') as f:f.write(mutant)
                pins[str(sourcefile)]=sha(sourcefile)
            command=[str(repo/'tools/verilator_serial.sh'),'-j','32','--binary','--timing','--assert',
                '--threads','1','-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '+define+VEN_FPREM','--Mdir',str(work/'obj'),'--top-module','tb_qacc_init_miter',
                str(package),str(control),str(sourcefile),str(tb)]
            save(label+'-command.json',command)
            with (work/'build.log').open('x') as f:
                build=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=240)
            assert build.returncode==0,(label,'compile',build.returncode)
            binary=work/'obj/Vtb_qacc_init_miter';pins[str(binary)]=sha(binary)
            with (work/'run.log').open('x') as f:
                run=subprocess.run([str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=60)
            log=(work/'run.log').read_text()
            runs.append(dict(label=label,native_exit=run.returncode,log_sha256=sha(work/'run.log')))
            if label=='candidate':
                assert run.returncode==0 and 'SRT-QACC-MITER-OK samples=5024 ' in log
            else:
                assert run.returncode!=0 and 'SRT_QACC_LIVE_MISMATCH' in log
        result['passed']=True
    except BaseException as error:
        import traceback
        result.update(error=repr(error),traceback=traceback.format_exc())
    result.update(seconds=time.monotonic()-begin,pins=pins,runs=runs,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
