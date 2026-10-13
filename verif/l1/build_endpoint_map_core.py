"""Compile the leaf-qualified endpoint map on the SMSW + PRIME-REG core.

Exact single-file change, unchanged UV-fast profile, private host translation
unit, bounded 32-job build. No inherited correctness, timing or FPGA pass.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_endpoint_map as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO/'verif/sys/smsw_memory'))
import build_core as native

MODEL = '42bd14c86eff5e33d98753cd07d34bf1340e804989daec237e42fd499565cfa5'
BUILDER_SHA = '9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'


def admit_leaf(root):
    done = native.load(root/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['whole_core']
    assert not done['hardware_acceptance'] and not done['standard_suite']
    assert [(r['name'],r['build_exit'],r['native_exit']) for r in done['rows']] == [
        ('positive',0,0), ('lost-tail-map',0,1), ('lost-mask-fallback',0,1),
        ('lost-zero-read-extent',0,1)]
    assert [(q['name'],q['result']) for q in done['queries']] == [
        ('same-line','unsat'), ('same-aperture','unsat'), ('unsafe-first-only','sat'),
        ('unsafe-subline-mask','sat'), ('wrap-is-exercisable','sat')]
    assert 'ENDPOINT-MAP-OK vectors=720896 checks=11534336 ' in done['rows'][0]['log']
    pins = dict(done['pins'])
    assert str(HERE/'prepare_endpoint_map.py') in pins
    assert str(HERE/'run_endpoint_map_leaf.py') in pins
    for row in done['rows']:
        pins.update(row['artifacts'])
    pins[str(root/'closed.json')] = native.sha(root/'closed.json')
    assert native.stable(pins)
    return pins


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent = args.parent.resolve(strict=True); leaf = args.leaf.resolve(strict=True)
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert native.sha(native.__file__) == BUILDER_SHA
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'], check=True, timeout=10)
    limits = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show','ventium-ipc-parallel32.scope',
        '-p','MemoryMax','-p','MemorySwapMax','-p','InvocationID'],text=True).splitlines())
    assert limits['MemoryMax'] == str(10*1024**3) and limits['MemorySwapMax'] == str(2*1024**3)
    old = native.load(parent/'build-started.json'); built = native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert native.sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert not built['canonical_gate_passed'] and not built['standard_suite']
    source = parent/'candidate'; files = native.common.candidate_files(source)
    assert len(files) == 195 and all(native.sha(p) == old['pins'][str(p)] for p in files)
    flags = [arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    changed = recipe.transform((source/recipe.FILE).read_text())
    assert changed == (leaf/'candidate'/recipe.FILE).read_text()
    pins = dict(old['pins']); pins.update(admit_leaf(leaf))
    for path in (Path(__file__), Path(recipe.__file__), Path(native.__file__),
                 Path(native.common.__file__), parent/'build-started.json',
                 parent/'build-closed.json', parent/'obj/tb_ventium'):
        pins[str(path.resolve())] = native.sha(path)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert sorted(str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')) == relative
    assert [p for p in relative if native.sha(source/p) != native.sha(root/'candidate'/p)] == [recipe.FILE]
    host = root/('tb_endpoint_map_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command = native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)] = native.sha(host)
    pins.update({str(root/'candidate'/p):native.sha(root/'candidate'/p) for p in relative})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.FILE],compiler_started=False,
        scope=limits,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None))
    # Preserve the audited native build, host/header check and timeout verbatim.
    native.MODEL = MODEL; native.CHANGES = [recipe.FILE]
    return native.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
