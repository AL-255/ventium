#!/usr/bin/env python3
"""Build actual parent/candidate SRT engines and compare their sequential outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_rem_clz_tree import transform


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('parent','core','out'):ap.add_argument('--'+flag,required=True,type=Path)
    a=ap.parse_args()
    parent,core,out=a.parent.resolve(strict=True),a.core.resolve(strict=True),a.out.resolve()
    repo=Path(__file__).resolve().parents[2]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([str(repo/'tools/build_scope.sh'),'--is-active'],pass_fds=(9,),check=True)
    fpu=core/'candidate/rtl/fpu'
    old=parent/'candidate/rtl/fpu/fpu_srt_div.sv'
    new=fpu/'fpu_srt_div.sv'
    assert new.read_text()==transform(old.read_text())
    assert sha(fpu/'fpu_x87_pkg.sv')==sha(parent/'candidate/rtl/fpu/fpu_x87_pkg.sv')
    for root in (parent,core):
        done=json.loads((root/'build-closed.json').read_text())
        assert done['passed'] and done['pins_unchanged'] and done['native_exit']==0
    out.mkdir()
    control=out/'fpu_srt_div_control.sv'
    assert old.read_text().count('module fpu_srt_div\n')==1
    with control.open('x') as f:f.write(old.read_text().replace('module fpu_srt_div\n','module fpu_srt_div_control\n'))
    tb=Path(__file__).with_name('tb_rem_clz_miter.sv')
    pins={str(p):sha(p) for p in (old,new,control,tb,Path(__file__),
        Path(__file__).with_name('prepare_rem_clz_tree.py'),fpu/'fpu_x87_pkg.sv',
        parent/'build-closed.json',core/'build-closed.json',repo/'tools/build_scope.sh',
        repo/'tools/verilator_serial.sh',Path('/tools/verilator/v5.046/bin/verilator'),
        Path('/tools/verilator/v5.046/bin/verilator_bin'))}
    def save(n,v):
        with (out/n).open('x') as f:json.dump(v,f,indent=2)
    command=[str(repo/'tools/verilator_serial.sh'),'-j','32','--binary','--timing','--assert',
        '--threads','1','-Wall','-Wno-UNUSED','-Wno-fatal','-Werror-IMPLICIT',
        '-Werror-PINMISSING','-Werror-UNDRIVEN','-Werror-MULTIDRIVEN','-Werror-LATCH',
        '-Werror-UNOPTFLAT','+define+VEN_FPREM','--Mdir',str(out/'obj'),
        '--top-module','tb_rem_clz_miter',str(fpu/'fpu_x87_pkg.sv'),str(control),str(new),str(tb)]
    save('started.json',dict(pins=pins,command=command,invocation=os.environ['INVOCATION_ID']))
    result=dict(passed=False,gameplay_ipc=None,whole_core=False,numeric_oracle=False)
    began=time.monotonic()
    try:
        with (out/'build.log').open('x') as f:
            built=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=300)
        result['build_exit']=built.returncode
        assert built.returncode==0
        binary=out/'obj/Vtb_rem_clz_miter'
        pins[str(binary)]=sha(binary)
        save('run-command.json',[str(binary)])
        with (out/'run.log').open('x') as f:
            run=subprocess.run([str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=90)
        result['native_exit']=run.returncode
        assert run.returncode==0
        assert 'SRT-CLZ-MITER-OK samples=4160 ' in (out/'run.log').read_text()
        result['passed']=True
    except BaseException as exc:
        import traceback
        result.update(error=repr(exc),traceback=traceback.format_exc())
    result.update(seconds=time.monotonic()-began,pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
