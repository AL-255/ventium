"""Run the unchanged six-harness route/extent/CD gate on both frozen seams.

This exercises actual L1, AXI and CDC state with the gate's ordinary memory-only
profile. It is not a UV processor test, full-system or hardware acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_endpoint_map as recipe
from run_parallel_tag_cache import archive_products, sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SOURCES = ['rtl/mem/'+n+'.sv' for n in
           ('ven_cdc_afifo','ven_reset_sync','ven_axi_cdc','ven_l1d','ven_axi_master')]
SOURCES += ['rtl/northbridge/ven_cachemap.sv',recipe.FILE]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args = parser.parse_args()
    roots = {k:getattr(args,k).resolve(strict=True) for k in ('parent','candidate')}
    out = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    before = roots['parent']/'candidate'; after = roots['candidate']/'candidate'
    assert recipe.transform((before/recipe.FILE).read_text()) == (after/recipe.FILE).read_text()
    pins = {}
    for root in roots.values():
        start = json.loads((root/'build-started.json').read_text())
        built = json.loads((root/'build-closed.json').read_text())
        assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
        for name in SOURCES:
            path = root/'candidate'/name
            assert sha(path) == start['pins'][str(path)]
            pins[str(path)] = sha(path)
        pins[str(root/'build-started.json')] = sha(root/'build-started.json')
        pins[str(root/'build-closed.json')] = sha(root/'build-closed.json')
    for name in SOURCES:
        if name != recipe.FILE:
            assert sha(before/name) == sha(after/name)
    for path in (Path(__file__),Path(recipe.__file__),HERE/'tb_l1axi_route.sv',
                 HERE/'axi_slave_bfm.sv',HERE/'run_parallel_tag_cache.py',
                 REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
                 Path(os.environ['VENTIUM_VERILATOR_BIN'])):
        pins[str(path.resolve())] = sha(path)
    out.mkdir()
    def save(name,value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),
         profile=['AXI_BFM_MON'],scope=__doc__))
    begin = time.monotonic(); rows = []
    result = dict(passed=False,whole_core=False,standard_suite=False,
                  hardware_acceptance=False,gameplay_ipc=None)
    try:
        for name,root in roots.items():
            folder = out/name; folder.mkdir()
            command = [str(REPO/'tools/verilator_serial.sh'),'-j','32','--binary','-sv','--assert',
                '+define+AXI_BFM_MON','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module','tb_l1axi_route','--Mdir',str(folder/'obj'),'-o','test',
                *[str(root/'candidate'/n) for n in SOURCES],
                str(HERE/'axi_slave_bfm.sv'),str(HERE/'tb_l1axi_route.sv')]
            row = dict(name=name,command=command); rows.append(row)
            with (folder/'build.log').open('x') as log:
                native = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=150)
            row['build_exit'] = native.returncode
            assert native.returncode == 0, (name,'compile')
            with (folder/'run.log').open('x') as log:
                native = subprocess.run([folder/'obj/test'],stdout=log,stderr=subprocess.STDOUT,timeout=60)
            row['native_exit'] = native.returncode; text = (folder/'run.log').read_text()
            assert native.returncode == 0 and 'L1AXIROUTE-GATE-OK' in text, (name,text)
            assert not re.search(r'%Fatal|%Error|FAIL',text), (name,text)
            row['artifacts'] = {str(p):sha(p) for p in (folder/'build.log',folder/'run.log',folder/'obj/test')}
            row['archive'] = archive_products(folder,'tb_l1axi_route')
            print(json.dumps(dict(name=name,native_exit=0)),flush=True)
        result['passed'] = True
    except Exception as error:
        result['error'] = repr(error)
    result.update(rows=rows,pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
