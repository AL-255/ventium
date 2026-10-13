"""Bind unchanged canonical/private-reference checks to the exact data-size cut.

The canonical cycle control uses the already audited single-fill parent, not
the older double-fill traces. No comparison, mask, golden or band is relaxed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import prepare_data_size as recipe

REPO=Path(__file__).resolve().parents[2]
BOARD=Path('/home/yukidama/external/tmp/ventium-cycle-backend.VAI7femO')
PARENT_MODEL='889bae534d468ae9c6ce14aa405e411b86f50a8f3bfbf7436f3bedbc990bb00a'


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=('canonical','func'))
    for n in ('core','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); core=a.core.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    started=json.loads((core/'build-started.json').read_text())
    closed=json.loads((core/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(core/'obj/tb_ventium')==closed['binary_sha256']
    parent=Path(started['parent']); board=BOARD.resolve(strict=True)
    assert parent==board/'board-core-r1'
    assert sha(parent/'obj/tb_ventium')==PARENT_MODEL
    assert started['changes']==[recipe.FILE]
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    audited=json.loads((board/'audit.json').read_text())
    assert audited['audit_passed'] and audited['parameter_delta']=={'AXI_LINE_REPLAY':[1,0]}
    pins={str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),core/'build-started.json',
        core/'build-closed.json',core/'obj/tb_ventium',board/'audit.json')}
    env=dict(os.environ)
    if a.mode=='canonical':
        source=REPO/'verif/issue_uv/run_fp_nomem_verify.py'
        assert sha(source)=='0b77257bd5624179105ddac6c2d7cf6f849c7701995d571c596d85e916a71dcb'
        cycles=board/'complete-r3'
        control=json.loads((cycles/'closed.json').read_text())
        assert control['diagnostic_completed'] and control['pins_unchanged']
        rows=[r for r in control['rows'] if r['latency']==7]
        assert len(rows)==20 and all(r['native_exit']==0 and r['affinity_observed'] for r in rows)
        for row in rows:
            assert row['command'][3]==str(parent/'obj/tb_ventium')
            for suffix in ('.vtrace','.closed.json'):
                path=cycles/(row['name']+'-lat7'+suffix); pins[str(path)]=sha(path)
        pins[str(cycles/'closed.json')]=sha(cycles/'closed.json')
        substitutions=[
            ('REPO = Path(__file__).resolve().parents[2]', 'REPO = Path('+repr(str(REPO))+')'),
            ("parent/'verify-closed.json'",'Path('+repr(str(cycles/'closed.json'))+')'),
            ("old = sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))",
             'old = sorted(Path('+repr(str(cycles))+').glob(\'*'+'-lat7.vtrace\'))'),
            ('[f.name for f in old] == [f.name for f in new]',
             "[f.name.replace('-lat7.vtrace','.cycle_rtl.vtrace') for f in old] == [f.name for f in new]")]
        env['TMPDIR']=str(core)
        tail=['--parent',str(parent),'--core',str(core)]
        limit=720
    else:
        source=REPO/'verif/qemu-trace/c1_reference/run_func.py'
        assert sha(source)=='9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'
        ancestor=Path(json.loads((parent/'build-started.json').read_text())['parent'])
        substitutions=[
            ('REPO=Path(__file__).resolve().parents[3]','REPO=Path('+repr(str(REPO))+')'),
            ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
             'assert sha(model)=='+repr(closed['binary_sha256'])),
            ("jobs_file=core/'generic-work/jobs.txt'",'jobs_file=Path('+repr(str(ancestor/'generic-work/jobs.txt'))+')')]
        oracle=scratch/'ventium-qemu-frndint.wRXifJwr'
        assert json.loads((oracle/'audit.json').read_text())['passed']
        tail=['--core',str(core),'--out',str(root),'--build',str(oracle/'build-r1'),'--probe',str(oracle/'probe-r1')]
        limit=600
    driver=root.with_suffix('.driver.py'); text=source.read_text()
    for before,after in substitutions:
        assert text.count(before)==1,before
        text=text.replace(before,after)
    compile(text,str(driver),'exec')
    with driver.open('x') as f: f.write(text)
    pins.update({str(p):sha(p) for p in (source,driver)})
    command=[sys.executable,'-B',str(driver),*tail]
    receipt=root.with_suffix('.driver.json')
    with receipt.open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=substitutions,mode=a.mode,
                       unmodified_comparisons=True,gameplay_ipc=None),f,indent=2)
    native=subprocess.run(command,env=env,timeout=limit)
    stable=all(sha(p)==h for p,h in pins.items())
    with root.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=native.returncode,pins_unchanged=stable,mode=a.mode),f,indent=2)
    assert stable
    return native.returncode


if __name__=='__main__': raise SystemExit(main())
