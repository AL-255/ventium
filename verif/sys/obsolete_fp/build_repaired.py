"""Build the two-file obsolete-x87 repair on the checked extent prototype.

Private source and model-specific host; frozen profile, no inherited acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_repaired as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO/'verif/sys/lmsw'))
from build_lmsw_core import native, BUILDER_SHA

MODEL = 'd039f5db76c653b249826d446dd5eab8ef9ac4d73243af6818a22cb26e4383c5'
CHANGES = sorted('rtl/core/'+name for name in recipe.PARENTS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'witness', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent, witness = args.parent.resolve(strict=True), args.witness.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert native.sha(native.__file__) == BUILDER_SHA
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    old, built = native.load(parent/'build-started.json'), native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    w, ws = native.load(witness/'closed.json'), native.load(witness/'started.json')
    assert w['passed'] and w['pins_unchanged'] and not w['repaired_rtl']
    assert len(w['rows']) == 32 and all(r['qemu_exit']==133 for r in w['rows'])
    assert sum(r['rtl_exit']==135 for r in w['rows']) == 6
    assert all(r['rtl_exit']==r['expected_rtl'] for r in w['rows'])
    assert native.stable(ws['pins']) and native.stable(w['artifacts'])
    source = parent/'candidate'; files = native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags = [s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'} <= set(definitions)
    changes = {'rtl/core/'+name:recipe.transform((source/'rtl/core'/name).read_text(),name)
               for name in recipe.PARENTS}
    pins = dict(old['pins']); pins.update(ws['pins']); pins.update(w['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              REPO/'verif/sys/lmsw/build_lmsw_core.py',parent/'build-started.json',
              parent/'build-closed.json',parent/'obj/tb_ventium',witness/'closed.json'):
        pins[str(p.resolve())] = native.sha(p)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    for name,text in changes.items(): (root/'candidate'/name).write_text(text)
    names = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')] == names
    assert [p for p in names if native.sha(source/p)!=native.sha(root/'candidate'/p)] == CHANGES
    host = root/('tb_obsolete_fp_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command = native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/p):native.sha(root/'candidate'/p) for p in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=CHANGES,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    native.MODEL=MODEL; native.CHANGES=CHANGES
    return native.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
