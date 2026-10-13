"""Bind unchanged whole-core gates to the exact environment-write decoder fix."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import prepare_write_class as recipe

REPO=Path(__file__).resolve().parents[3]


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=('canonical','func'))
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();core=a.core.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    started=json.loads((core/'build-started.json').read_text())
    closed=json.loads((core/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(core/'obj/tb_ventium')==closed['binary_sha256']
    parent=scratch/'ventium-data-size.v2HaTO2X/core-r1'
    assert Path(started['parent'])==parent and started['changes']==[recipe.FILE]
    assert sha(parent/'obj/tb_ventium')==started['parent_model']=='fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    pins={str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),core/'build-started.json',
        core/'build-closed.json',core/'obj/tb_ventium')}
    env=dict(os.environ)
    if a.mode=='canonical':
        source=REPO/'verif/issue_uv/run_fp_nomem_verify.py'
        assert sha(source)=='0b77257bd5624179105ddac6c2d7cf6f849c7701995d571c596d85e916a71dcb'
        text=source.read_text()
        substitutions=[('REPO = Path(__file__).resolve().parents[2]',
                        'REPO = Path('+repr(str(REPO))+')')]
        env['TMPDIR']=str(core)
        tail=['--parent',str(parent),'--core',str(core)];limit=720
    else:
        source=REPO/'verif/qemu-trace/c1_reference/run_func.py'
        assert sha(source)=='9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
        text=source.read_text()
        substitutions=[
            ('REPO=Path(__file__).resolve().parents[3]','REPO=Path('+repr(str(REPO))+')'),
            ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
             'assert sha(model)=='+repr(closed['binary_sha256'])),
            ("jobs_file=core/'generic-work/jobs.txt'",'jobs_file=Path('+repr(str(parent/'generic-work/jobs.txt'))+')'),
            ('set(range(8,12))','set(range(13,17))'),
            ('cpu=8+index%4','cpu=13+index%4')]
        oracle=scratch/'ventium-qemu-frndint.wRXifJwr'
        assert json.loads((oracle/'audit.json').read_text())['passed']
        tail=['--core',str(core),'--out',str(root),'--build',str(oracle/'build-r1'),
              '--probe',str(oracle/'probe-r1')];limit=600
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    driver=root.with_suffix('.driver.py');compile(text,str(driver),'exec')
    with driver.open('x') as f:f.write(text)
    pins.update({str(p):sha(p) for p in (source,driver)})
    command=[sys.executable,'-B',str(driver),*tail]
    with root.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=substitutions,mode=a.mode,
                       unmodified_comparisons=True,gameplay_ipc=None),f,indent=2)
    native=subprocess.run(command,env=env,timeout=limit)
    stable=all(sha(p)==h for p,h in pins.items())
    with root.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=native.returncode,pins_unchanged=stable,mode=a.mode),f,indent=2)
    assert stable
    return native.returncode


if __name__=='__main__':raise SystemExit(main())
