#!/usr/bin/env python3
"""Build the one-function SRT CLZ experiment from the frozen write-direction core."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_rem_clz_tree import PARENT, transform


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+key, required=True, type=Path)
    args = ap.parse_args()
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'],
                          pass_fds=(9,)).returncode == 0
    old = json.loads((parent/'build-started.json').read_text())
    closed = json.loads((parent/'build-closed.json').read_text())
    expected = '1bfb1bb2f6179ba13384cfdd3f4ded7ac5742108ef21add23e6da1f301286e8c'
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==sha(parent/'obj/tb_ventium')==expected
    checked = json.loads((leaf/'closed.json').read_text())
    assert checked['passed'] and checked['pins_unchanged']
    assert [(r['label'],r['native_exit']) for r in checked['runs']]==[
        ('proof-positive',0),('build-positive',0),('positive',0),
        ('proof-wrong-zero',0),('build-wrong-zero',0),('wrong-zero',1),
        ('proof-wrong-half',0),('build-wrong-half',0),('wrong-half',1)]
    for row in checked['runs']:
        assert sha(leaf/(row['label']+'.log'))==row['log_sha256']
    assert 'REM-CLZ-TREE-OK samples=393410' in (leaf/'positive.log').read_text()
    assert (leaf/'proof-positive.log').read_text().strip()=='unsat'
    for name in ('wrong-zero','wrong-half'):
        assert (leaf/('proof-'+name+'.log')).read_text().strip()=='sat'
        assert 'REM_CLZ_TREE_MISMATCH' in (leaf/(name+'.log')).read_text()
    pins = {**old['pins'], **checked['pins']}
    assert all(sha(p)==h for p,h in pins.items())
    name = 'rtl/fpu/fpu_srt_div.sv'
    assert sha(parent/'candidate'/name)==PARENT
    leaves = [p for p in checked['pins'] if p.endswith('/'+name)]
    assert len(leaves)==1 and sha(leaves[0])==sha(parent/'candidate'/name)
    changed = transform((parent/'candidate'/name).read_text())
    root.mkdir()
    shutil.copytree(parent/'candidate',root/'candidate')
    (root/'candidate'/name).write_text(changed)
    changes = [str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'candidate'/p.relative_to(root/'candidate'))]
    assert changes==[name]
    oldhost = Path(old['host'])
    host = root/('tb_srt_clz_tree_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost,host)
    command = [s.replace(str(parent/'candidate'),str(root/'candidate'))
        .replace(str(parent/'obj'),str(root/'obj')).replace(str(oldhost),str(host))
        for s in old['command']]
    for p in (Path(__file__),Path(__file__).with_name('prepare_rem_clz_tree.py'),
        parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
        leaf/'closed.json',host):
        pins[str(p)]=sha(p)
    for p in (root/'candidate').rglob('*'):
        if p.is_file(): pins[str(p)]=sha(p)

    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)

    save('build-started.json',dict(command=command,pins=pins,host=str(host),
        parent_model=expected,changes=changes,affinity=sorted(os.sched_getaffinity(0)),
        invocation=os.environ['INVOCATION_ID'],gameplay_ipc=None))
    result = dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False)
    began = time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            p = subprocess.run(command,env={**os.environ,'CCACHE_DISABLE':'1'},
                stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=600)
        result['native_exit']=p.returncode
        assert p.returncode==0
        obj=root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except BaseException as exc:
        import traceback
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-began)
    result['passed'] &= result['pins_unchanged']
    save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
