"""Strict CPU lint for the sealed 159-define, 192-file AUX/mouse export.

Only profile admission and the private driver's repository path differ from
the established CPU lint runner. Structural warning policy is unchanged.
This does not qualify full-wrapper wiring or inherited full-SoC lint debt.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import lint_frozen_rk_core as base
import freeze_v_result_carry_rk_candidate as export


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('source','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--manifest-sha256',required=True);a=ap.parse_args()
    source=a.source.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out!=scratch and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert base.sha(source/'input-manifest.json')==a.manifest_sha256
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='v_result_carry_aux_mouse_unqualified'
    assert manifest['processor_platform_simulator_sha256']==export.MODEL
    defs=(source/'defines.txt').read_text().splitlines()
    assert len(defs)==len(set(defs))==159 and 'VEN_X87_MF_STRICT' in defs
    assert 'VEN_P54_REGMEM_PRIME' not in defs
    original=Path(base.__file__);text=original.read_text()
    edits=[('REPO = Path(__file__).resolve().parents[1]','REPO = Path('+repr(str(base.REPO))+')'),
           ('len(definitions) == len(set(definitions)) == 156','len(definitions) == len(set(definitions)) == 159'),
           ('len(pins) == len(manifest[\'files\']) == 190','len(pins) == len(manifest[\'files\']) == 192')]
    for old,new in edits:assert text.count(old)==1;text=text.replace(old,new)
    recovered=text
    for old,new in reversed(edits):assert recovered.count(new)==1;recovered=recovered.replace(new,old)
    assert recovered==original.read_text()
    driver=out.with_suffix('.driver.py')
    with driver.open('x') as f:f.write('import sys\nsys.path.insert(0, '+repr(str(original.parent))+')\n'+text)
    pins={str(p):base.sha(p) for p in (Path(__file__),original,driver,Path(export.__file__))}
    command=[sys.executable,'-B',str(driver),'--source',str(source),'--out',str(out),
             '--manifest-sha256',a.manifest_sha256]
    with out.with_suffix('.driver.json').open('x') as f:json.dump(dict(pins=pins,command=command,substitutions=edits),f,indent=2)
    status=subprocess.run(command,timeout=330).returncode
    assert all(base.sha(Path(p))==h for p,h in pins.items())
    return status


if __name__=='__main__':raise SystemExit(main())
