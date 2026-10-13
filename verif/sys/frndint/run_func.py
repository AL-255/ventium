"""Reuse the exact private-reference worker with only model/job-source rebinding."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO=Path(__file__).resolve().parents[3]


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','core','build','probe','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();core=a.core.resolve(strict=True);parent=a.parent.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert os.sched_getaffinity(0)==set(range(8,12)) and Path(os.environ['TMPDIR']).resolve()==scratch
    source=REPO/'verif/qemu-trace/c1_reference/run_func.py'
    assert sha(source)=='9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
    built=json.loads((core/'build-closed.json').read_text())
    prepared=json.loads((core/'prepared.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert Path(prepared['parent']).resolve()==parent
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')
    text=source.read_text()
    old="assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'"
    assert text.count(old)==1;text=text.replace(old,'assert sha(model)=='+repr(built['binary_sha256']))
    old="jobs_file=core/'generic-work/jobs.txt'"
    assert text.count(old)==1;text=text.replace(old,'jobs_file=Path('+repr(str(parent/'generic-work/jobs.txt'))+')')
    old='REPO=Path(__file__).resolve().parents[3]'
    assert text.count(old)==1;text=text.replace(old,'REPO=Path('+repr(str(REPO))+')')
    driver=out.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    pins={str(p):sha(p) for p in (Path(__file__),source,driver,core/'prepared.json',core/'build-closed.json')}
    command=[sys.executable,'-B',str(driver),'--core',str(core),'--out',str(out),
             '--build',str(a.build.resolve(strict=True)),'--probe',str(a.probe.resolve(strict=True))]
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,only_model_and_job_source_rebound=True),f,indent=2)
    code=subprocess.run(command,timeout=600).returncode
    assert all(sha(p)==h for p,h in pins.items())
    return code


if __name__=='__main__':raise SystemExit(main())
