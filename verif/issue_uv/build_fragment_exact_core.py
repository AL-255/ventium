#!/usr/bin/env python3
"""Build the exact-read correction privately, after the sole Vivado run closes.

Preserve the BUS model's complete source closure, 150 UV-fast definitions and
private model-dependent C++ harness. This never edits the canonical dirty RTL.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import build_bus_cancel_core as common
from prepare_fragment_exact_reads import transform

REPO = Path(__file__).resolve().parents[2]
MODEL = 'f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'
AUDIT = '1c6738e1a201bb9367d5180e1c45110dc7ed36e6ea2f1601daa6c3e6249f564a'
PAYLOAD = 'rtl/core/core.sv'
sha, save, load, stable = common.sha, common.save, common.load, common.stable


def prepare(parent, leaf, root):
    assert not root.exists()
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    audit_path = parent.parent/'core-audit.json'
    assert sha(audit_path) == AUDIT
    audit = load(audit_path)
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == audit['model_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    assert audit['audit_complete'] and audit['directed_regressions_passed'] and not audit['canonical_gate_passed']
    checked = load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors'] and not checked['whole_core']
    expected = []
    for name, status in (('positive',0), ('predecessor',1), ('bad-first-mask',1),
                         ('bad-saved-mask',1), ('bad-owner',1)):
        expected.extend(((name+'-build',0), (name,status)))
    assert [(row['label'],row['native_exit']) for row in checked['rows']] == expected
    assert 'FRAGMENT-EXACT-OK reads=216 replacements=144 walks=180 writes=64 pieces=872' in (leaf/'positive.log').read_text()
    pins = dict(checked['pins'])
    for row in checked['rows']:
        path = leaf/(row['label']+'.log')
        assert sha(path) == row['log_sha256']
        pins[str(path)] = sha(path)
    source = parent/'candidate'; files = common.candidate_files(source)
    for path in files:
        assert sha(path) == old['pins'][str(path)]
        pins[str(path)] = sha(path)
    fixed = transform((source/PAYLOAD).read_text(), (source/'rtl/core/core_bus_driver.svh').read_text())
    assert fixed == (leaf/'candidate-core.sv').read_text()
    flags = next(arg for arg in old['command'] if arg.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)', flags)
    assert len(definitions) == len(set(definitions)) == 150 and '--assert' in flags
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_L1_AXI'} <= set(definitions)
    assert 'VL_J=32' in old['command']
    cpp = next(arg for arg in old['command'] if arg.startswith('CPP_SRCS=')).split('=',1)[1].split()
    for name in cpp:
        path = Path(name); pins[str(path)] = sha(path)
        dep = parent/'obj'/(path.stem+'.d'); pins[str(dep)] = sha(dep)
        for name in dep.read_text().replace('\\\n',' ').split()[1:]:
            path = Path(name)
            if path.is_absolute():
                pins[str(path)] = sha(path)
    dependencies = [Path(__file__), Path(common.__file__),
        Path(__file__).with_name('prepare_fragment_exact_reads.py'),
        Path(__file__).with_name('prepare_fragment_read_payload.py'),
        REPO/'verif/l1/build_mc_branch_residency_core.py', REPO/'verif/tb/Makefile',
        REPO/'verif/tb/model_input_snapshot.mk', REPO/'tools/gen_model_input_snapshot.py',
        REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
        parent/'build-started.json', parent/'build-closed.json', audit_path,
        leaf/'started.json', leaf/'closed.json']
    pins.update({str(path):sha(path) for path in dependencies})
    assert stable(pins)
    root.mkdir(); shutil.copytree(source, root/'candidate')
    (root/'candidate'/PAYLOAD).write_text(fixed)
    relative = [str(path.relative_to(source)) for path in files]
    assert [str(path.relative_to(root/'candidate')) for path in common.candidate_files(root/'candidate')] == relative
    assert [name for name in relative if sha(source/name)!=sha(root/'candidate'/name)] == [PAYLOAD]
    host = root/('tb_fragment_exact_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(old['host'], host)
    command = common.relocate(old['command'], parent, root, Path(old['host']), host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/name):sha(root/'candidate'/name) for name in relative})
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, parent=str(parent),
        host=str(host), definitions=definitions, parent_model=MODEL, changes=[PAYLOAD],
        compiler_started=False, canonical_gate_passed=False, gameplay_ipc=None))
    print(json.dumps(dict(prepared=str(root), source_files=len(relative), pins=len(pins))), flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists() and os.environ.get('INVOCATION_ID')
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert stable(before['pins']) and before['parent_model']==MODEL and before['changes']==[PAYLOAD]
    old = load(Path(before['parent'])/'build-started.json')
    assert before['command'] == common.relocate(old['command'], Path(before['parent']), root,
                                                Path(old['host']), Path(before['host']))
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'], check=True, timeout=10)
    save(root/'build-started.json', dict(before, compiler_started=True,
        preparation_sha256=sha(root/'prepared.json'), invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None,
        standard_suite=False, hardware_acceptance=False); began = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(before['command'], env={**os.environ,'CCACHE_DISABLE':'1'},
                stdout=stream, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj, host = root/'obj', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(name) for name in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(name).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(before['pins']), seconds=time.monotonic()-began)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare','build'))
    parser.add_argument('--parent',type=Path); parser.add_argument('--leaf',type=Path)
    parser.add_argument('--out',type=Path,required=True); args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True); root=args.out.resolve()
    assert __debug__ and root!=scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert args.parent and args.leaf
        prepare(args.parent.resolve(strict=True),args.leaf.resolve(strict=True),root)
        return 0
    return build(root)


if __name__=='__main__':
    raise SystemExit(main())
