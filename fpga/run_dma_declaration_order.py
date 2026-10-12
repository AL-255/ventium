"""Four-state, public-I/O test of the actual i8237 and a private declaration fix.

Small Icarus compilation only; no C++ build, Vivado, active-export edits or
physical acceptance claim. Keep original failures and incomplete-fix controls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

import prepare_dma_declaration_order as recipe

REPO=Path(__file__).resolve().parents[1]
def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args(); source=args.source.resolve(strict=True); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and sha(source)==recipe.PARENT
    tb=REPO/'fpga/tb_dma_declaration_order.sv'
    pins={str(p):sha(p) for p in (source,tb,Path(recipe.__file__),Path(__file__))}
    parent=source.read_text(); out.mkdir()
    def save(name,v):
        with (out/name).open('x') as f:json.dump(v,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),
                            compiler='/usr/bin/iverilog',hardware_acceptance=False))
    variants={'parent':parent,'fixed':recipe.transform(parent),
              'only-selector':recipe.transform(parent,reset=False),
              'only-reset':recipe.transform(parent,selector=False)}
    results=[]
    for name,text in variants.items():
        leaf=out/name; leaf.mkdir(); rtl=leaf/'dma.v'; rtl.write_text(text)
        binary=leaf/'test.vvp'
        compile_cmd=['/usr/bin/iverilog','-g2012','-Wall','-s','tb_dma_declaration_order',
                     '-o',str(binary),str(rtl),str(tb)]
        compiled=subprocess.run(compile_cmd,capture_output=True,text=True,timeout=15)
        (leaf/'compile.log').write_text(compiled.stdout+compiled.stderr)
        assert compiled.returncode==0,(name,compiled.stderr)
        executed=subprocess.run(['/usr/bin/vvp',str(binary)],capture_output=True,text=True,timeout=15)
        log=executed.stdout+executed.stderr; (leaf/'run.log').write_text(log)
        results.append(dict(name=name,compile_exit=compiled.returncode,native_exit=executed.returncode,
                            output=log,source_sha256=sha(rtl),binary_sha256=sha(binary)))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(pins_unchanged=stable,variants=results,physical_board=False)
    result['passed']=(stable and results[1]['native_exit']==0 and 'checks=74' in results[1]['output']
        and all(r['native_exit']!=0 for r in (results[0],results[2],results[3]))
        and 'DMA-SOFT-RESET' in results[2]['output']
        and all('DMA-BYTE-SELECT' in r['output'] for r in (results[0],results[3])))
    save('closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
