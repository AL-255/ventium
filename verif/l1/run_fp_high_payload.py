"""Actual-source wide-response payload equivalence and reset/denial negatives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import prepare_fp_high_payload as recipe


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    out=a.out.resolve(); assert out.is_relative_to(scratch)
    out.mkdir()
    source=a.source.resolve(strict=True)
    fixture=Path(__file__).with_name('tb_fp_high_payload.sv')
    pins={str(p.resolve()):sha(p) for p in (source,fixture,Path(__file__),Path(recipe.__file__))}
    text=source.read_text(); recipe.transform(text)
    template=fixture.read_text()
    assert template.count('  // SOURCE_EXPRESSIONS')==1
    with (out/'started.json').open('x') as f:
        json.dump(dict(pins=pins,invocation=os.environ.get('INVOCATION_ID')),f,indent=2)
    begin=time.monotonic(); rows=[]; errors=[]
    try:
        for name,mutant in (('candidate',None),('wrong-valid-word','word'),('deny-leak','deny')):
            leaf=out/name; leaf.mkdir()
            payload=recipe.NEW.replace('core_rdata_hi =','new_data =')
            if mutant=='word': payload=payload.replace(' : l1d_c_rdata_hi;'," : (l1d_c_rdata_hi ^ 32'd1);")
            if mutant=='deny': payload=payload.replace('(core_smram_deny || core_route_deny)',"1'b0")
            sv=leaf/'tb.sv'
            expressions='\n'.join((recipe.REQUEST,recipe.VALID,
                recipe.OLD.replace('core_rdata_hi =','old_data ='),payload))
            with sv.open('x') as f: f.write(template.replace('  // SOURCE_EXPRESSIONS',expressions))
            command=['iverilog','-g2012','-s','tb','-o',str(leaf/'test.vvp'),str(sv)]
            with (leaf/'command.json').open('x') as f: json.dump(command,f)
            with (leaf/'build.log').open('x') as f:
                build=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=20)
            assert build.returncode==0,(name,'build',build.returncode)
            with (leaf/'run.log').open('x') as f:
                native=subprocess.run(['vvp',str(leaf/'test.vvp')],stdout=f,stderr=subprocess.STDOUT,timeout=30)
            log=(leaf/'run.log').read_text()
            if mutant:
                marker='VALID-PAYLOAD mismatch' if mutant=='word' else 'DENIED-PAYLOAD exposed'
                assert native.returncode==1 and marker in log,(name,native.returncode,log)
                counts=None
            else:
                markers=re.findall(r'^FP-HIGH-PAYLOAD-OK checks=(\d+) valid=(\d+) denied=(\d+) early=(\d+)$',log,re.M)
                assert native.returncode==0 and len(markers)==1,(name,native.returncode,log)
                counts=list(map(int,markers[0]))
                assert counts[:2]==[45076,44]
            rows.append(dict(name=name,native_build=build.returncode,native_run=native.returncode,
                expected_failure=bool(mutant),counts=counts,source_sha256=sha(sv),binary_sha256=sha(leaf/'test.vvp')))
    except Exception as exc:
        errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=not errors and stable and len(rows)==3,rows=rows,errors=errors,
        pins_unchanged=stable,seconds=time.monotonic()-begin,full_core=False,
        gameplay_ipc=None,hardware_timing=False,standard_suite=False)
    with (out/'closed.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps(result,indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
