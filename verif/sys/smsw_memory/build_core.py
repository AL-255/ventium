"""Prepare/build an isolated general SMSW store-path repair on PRIME-CS.

Preserve the exact 195-source closure and 152 UV-fast definitions. Never edit
the frozen parent, use its model-dependent host object, or compile with Vivado
live. Build success is not correctness or FPGA acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO/'verif/srt'))
import build_input_norm_core as common

MODEL = '73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca'
CHANGES = sorted('rtl/core/'+name for name in recipe.PARENTS)
sha, load, save, stable = common.sha, common.load, common.save, common.stable


def prepare(args, root):
    parent, probes = [getattr(args,key).resolve(strict=True) for key in ('parent','probes')]
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    checked = load(probes/'audit.json')
    assert checked['passed'] and checked['exact_instruction_and_fault_pc']
    assert (checked['qemu_success'], checked['missing_opcode_cases'], checked['mov_controls']) == (88,80,8)
    assert not checked['repaired_rtl'] and not checked['differential_gate']
    assert stable(checked['artifacts'])
    source = parent/'candidate'
    files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(path) == old['pins'][str(path)] for path in files)
    flags = [arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags) == 1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions = re.findall(r'\+define\+(\w+)', flags[0])
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    changes = {'rtl/core/'+name:recipe.transform((source/'rtl/core'/name).read_text(),name)
               for name in recipe.PARENTS}
    pins = {**old['pins'], **checked['artifacts']}
    for path in (Path(__file__), Path(recipe.__file__), Path(common.__file__),
                 REPO/'verif/l1/build_mc_branch_residency_core.py', HERE/'test_prepare.py',
                 probes/'audit.json', parent/'obj/tb_ventium',
                 parent/'build-started.json', parent/'build-closed.json'):
        pins[str(path.resolve())] = sha(path)
    assert stable(pins)
    root.mkdir()
    shutil.copytree(source,root/'candidate')
    for path,text in changes.items():
        (root/'candidate'/path).write_text(text)
    relative = [str(path.relative_to(source)) for path in files]
    assert [str(path.relative_to(root/'candidate')) for path in common.candidate_files(root/'candidate')] == relative
    assert sorted(path for path in relative if sha(source/path) != sha(root/'candidate'/path)) == CHANGES
    host = root/('tb_smsw_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command = common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/path):sha(root/'candidate'/path) for path in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=CHANGES,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print('SMSW-CORE-PREPARED '+str(root),flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins'])
    old = load(Path(before['parent'])/'build-started.json')
    assert before['parent_model'] == MODEL and before['changes'] == CHANGES
    assert before['command'] == common.relocate(old['command'],Path(before['parent']),root,
                                               Path(old['host']),Path(before['host']))
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    save(root/'build-started.json',dict(before,compiler_started=True,invocation=os.environ['INVOCATION_ID'],
        preparation_sha256=sha(root/'prepared.json'),affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False,errors=[],canonical_gate_passed=False,standard_suite=False,
                  hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(before['command'],env=dict(os.environ,CCACHE_DISABLE='1'),
                                    stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj, host = root/'obj',Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(name) for name in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(name).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=stable(before['pins']))
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result)
    print(result,flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build'))
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--parent',type=Path)
    parser.add_argument('--probes',type=Path)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.probes and not root.exists()
        prepare(args,root)
    else:
        raise SystemExit(build(root))
