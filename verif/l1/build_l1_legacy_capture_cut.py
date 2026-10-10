#!/usr/bin/env python3
"""Create a source-matched whole-core model after the L1 miter passes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from prepare_l1_legacy_capture_cut import transform


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('parent','leaf','out'):
        ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    parent=args.parent.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    root=args.out.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=parent
    assert not root.is_relative_to(parent) and not parent.is_relative_to(root)
    assert Path(os.environ['TMPDIR']).resolve()==root
    assert shutil.disk_usage(root).free>4*1024**3
    old=json.loads((parent/'build-started.json').read_text())
    closed=json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==closed['binary_sha256']=='16b7e9e2c2c12a9ce3e15c8f5c8fabe0f8e61df92d3e57fa205b66ee8d7b4410'
    checked=json.loads((leaf/'closed.json').read_text())
    assert checked['passed'] and checked['pins_unchanged'] and len(checked['rows'])==4
    pins=dict(old['pins']); pins.update(json.loads((leaf/'pins.json').read_text()))
    assert all(sha(p)==h for p,h in pins.items())
    shutil.copytree(parent/'candidate',root/'candidate')
    target=root/'candidate/rtl/mem/ven_l1d.sv'
    target.write_text(transform(target.read_text()))
    assert sha(target)==sha(leaf/'hardware/ven_l1d.sv')
    changes=[str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*')
             if p.is_file() and sha(p)!=sha(parent/'candidate'/p.relative_to(root/'candidate'))]
    assert changes==['rtl/mem/ven_l1d.sv']
    oldhost=Path(old['host']); host=root/('tb_l1_capture_cut_'+root.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost,host)
    command=[s.replace(str(parent/'candidate'),str(root/'candidate')).replace(str(parent/'obj'),str(root/'obj'))
             .replace(str(oldhost),str(host)) for s in old['command']]
    for p in (Path(__file__),Path(__file__).with_name('prepare_l1_legacy_capture_cut.py'),
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
              leaf/'closed.json',leaf/'pins.json',host): pins[str(p)]=sha(p)
    for p in (root/'candidate').rglob('*'):
        if p.is_file(): pins[str(p)]=sha(p)

    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2); f.write('\n')

    save('build-started.json',dict(command=command,pins=pins,host=str(host),changes=changes,
        parent_model=closed['binary_sha256'],invocation=os.environ.get('INVOCATION_ID'),gameplay_ipc=None))
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result=dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False)
    start=time.monotonic()
    try:
        with (root/'build.log').open('x') as log:
            p=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        result['native_exit']=p.returncode
        assert p.returncode==0
        obj=root/'obj'; assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error: result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged']; save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
