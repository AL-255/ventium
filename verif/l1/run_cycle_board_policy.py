"""Reuse the exact diagnostic/corpus drivers with audited model rebinding."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=('cycle','func'))
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();core=a.core.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    built=json.loads((core/'build-closed.json').read_text())
    started=json.loads((core/'build-started.json').read_text());parent=Path(started['parent'])
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')
    assert started['parameter_delta']=={'AXI_LINE_REPLAY':[1,0]} and started['changes']==[]
    substitutions=[]
    if a.mode=='cycle':
        source=REPO/'verif/l1/run_cycle_backend_profile.py'
        assert sha(source)=='8f264ae6a198b10b6ef4b66ab08632d49ef78c36cfc6d64360616ce1d053e0de'
        substitutions=[
            ("PARENT=Path('/home/yukidama/external/tmp/ventium-frndint.tM8XCg6d/core-r1')",'PARENT=Path('+repr(str(core))+')'),
            ("MODEL='2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63'",'MODEL='+repr(built['binary_sha256'])),
            ("work=core/'generic-work'",'work=Path('+repr(str(parent/'generic-work'))+')'),
            ("assert '-GAXI_LINE_REPLAY' not in", "assert '-GAXI_LINE_REPLAY=0' in"),
            ("assert args[0]==str(core/'obj/tb_ventium')",'assert args[0]=='+repr(str(parent/'obj/tb_ventium'))),
            ("gold=Path((work/(name+'.cycle.result'))", "args[0]=str(core/'obj/tb_ventium')\n        gold=Path((work/(name+'.cycle.result'))"),
            ("if latency==7:assert records==expected, 'profiling must be passive'", "# Deliberate replay-policy delta: PC/order must match; clocks can change."),
            ("line_replay=1,latencies", "line_replay=0,latencies"),
            ("passive_trace_equal=latency==7", "passive_trace_equal=False")]
        tail=['--out',str(out)]
    else:
        source=REPO/'verif/qemu-trace/c1_reference/run_func.py'
        assert sha(source)=='9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
        substitutions=[
            ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",'assert sha(model)=='+repr(built['binary_sha256'])),
            ("jobs_file=core/'generic-work/jobs.txt'",'jobs_file=Path('+repr(str(parent/'generic-work/jobs.txt'))+')')]
        qroot=scratch/'ventium-qemu-frndint.wRXifJwr'
        assert json.loads((qroot/'audit.json').read_text())['passed']
        tail=['--core',str(core),'--out',str(out),'--build',str(qroot/'build-r1'),'--probe',str(qroot/'probe-r1')]
    substitutions.append(('REPO=Path(__file__).resolve().parents[2]' if a.mode=='cycle' else
                          'REPO=Path(__file__).resolve().parents[3]','REPO=Path('+repr(str(REPO))+')'))
    text=source.read_text()
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    compile(text,str(out.with_suffix('.driver.py')),'exec')
    driver=out.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    pins={str(p):sha(p) for p in (Path(__file__),source,driver,core/'build-closed.json',core/'build-started.json')}
    command=[sys.executable,'-B',str(driver),*tail]
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=substitutions,mode=a.mode),f,indent=2)
    code=subprocess.run(command,timeout=600).returncode
    assert all(sha(p)==h for p,h in pins.items())
    return code


if __name__=='__main__':raise SystemExit(main())
