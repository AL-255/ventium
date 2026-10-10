#!/usr/bin/env python3
"""Source-pinned register-only admission derivative; no deployment or acceptance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve(strict=True)
    parent = args.parent.resolve(strict=True)
    here = Path(__file__).resolve().parent
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != parent
    assert not root.is_relative_to(parent) and not parent.is_relative_to(root)
    assert Path(os.environ['TMPDIR']).resolve() == root
    assert shutil.disk_usage(root).free > 4*1024**3
    prior = json.loads((parent/'build-started.json').read_text())
    closed = json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == closed['binary_sha256'] == 'f74dd76ba78e2a09db09be0a69c58f08164b19f1d38782c6050492a34d27e9e5'
    leaf = json.loads((root/'leaf/closed.json').read_text())
    assert leaf['passed'] and leaf['pins_unchanged'] and len(leaf['rows']) == 4
    pins = dict(prior['pins'])
    pins.update(leaf['pins'])
    assert all(sha(p) == h for p, h in pins.items())
    tool = here/'prepare-prefix-ex-regonly.py'
    spec = importlib.util.spec_from_file_location('regonly', tool)
    recipe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recipe)
    shutil.copytree(parent/'candidate', root/'candidate')
    target = root/'candidate/rtl/core/core_prefix_ex_chain.svh'
    target.write_text(recipe.transform(target.read_text()))
    assert sha(target) == sha(root/'leaf/system/core_prefix_ex_chain.svh')
    changes = sorted(str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*')
                     if p.is_file() and sha(p) != sha(parent/'candidate'/p.relative_to(root/'candidate')))
    assert changes == ['rtl/core/core_prefix_ex_chain.svh']
    assert not any('p54_prefix_ex_shape_ok' in p.read_text() for p in (root/'candidate/rtl/core').iterdir()
                   if p.is_file() and p.suffix in ('.sv', '.svh') and p != target)
    oldhost = Path(prior['host'])
    host = root/('tb_prefix_regonly_'+root.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = [s.replace(str(parent/'candidate'),str(root/'candidate')).replace(str(parent/'obj'),str(root/'obj'))
               .replace(str(oldhost),str(host)) for s in prior['command']]
    assert [s for s in command if s.startswith('VL_EXTRA_DEFINES=')] == [s for s in prior['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    for p in (Path(__file__),tool,parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium',root/'leaf/closed.json',host):
        pins[str(p)] = sha(p)
    for p in (root/'candidate').rglob('*'):
        if p.is_file():
            pins[str(p)] = sha(p)

    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')

    save('build-started.json', dict(command=command,pins=pins,changes=changes,host=str(host),
         parent_model=closed['binary_sha256'],invocation=os.environ.get('INVOCATION_ID'),gameplay_ipc=None))
    env = dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False,errors=[],production_changed=False,gameplay_ipc=None,standard_suite=False)
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as log:
            run = subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        result['native_exit'] = run.returncode
        assert run.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged']
        save('build-closed.json', result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
