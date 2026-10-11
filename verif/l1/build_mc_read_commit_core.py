#!/usr/bin/env python3
"""Build one private read-hint commit derivative of the 30.348 MHz candidate."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare_mc_read_commit as patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
import build_bus_cancel_core as common

MODEL = '64e997d504e7f73fcd1f6b5e524a68cb6f901bf88f44b97fb613dfa1adf9d055'
TARGET = 'rtl/core/core_mem_chain.svh'
sha, save, load, stable = common.sha, common.save, common.load, common.stable


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','formal','out'):
        ap.add_argument('--'+name,type=Path,required=True)
    args = ap.parse_args()
    parent, leaf, formal = [getattr(args,name).resolve(strict=True)
                            for name in ('parent','leaf','formal')]
    root = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    before, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    checked, proof = load(leaf/'closed.json'), load(formal/'closed.json')
    assert checked['passed'] and checked['pins_unchanged']
    assert proof['passed'] and proof['pins_unchanged'] and proof['abstract_predicate_proof']
    assert [(r['label'],r['native_exit']) for r in checked['rows']] == [
        ('positive',0),('missing-read-ack',1),('raw-fragment-ack',1),('lost-fp-admission',1)]
    assert [(r['label'],r['answer']) for r in proof['rows']] == [
        ('positive','unsat'),('missing-read-ack','sat'),('raw-fragment-ack','sat'),
        ('lost-fp-admission','sat'),('allow-store-prime','sat')]
    pins = {**before['pins'],**proof['pins']}
    for row in checked['rows']:
        pins.update(row['artifacts'])
    for row in proof['rows']:
        path = formal/(row['label']+'.smt2')
        assert sha(path) == row['query_sha256']
        assert (formal/(row['label']+'.log')).read_text().strip() == row['answer']
        pins[str(path)] = sha(path)
        pins[str(formal/(row['label']+'.log'))] = sha(formal/(row['label']+'.log'))
    files = common.candidate_files(parent/'candidate')
    assert len(files) == 195 and all(sha(p) == before['pins'][str(p)] for p in files)
    core = (parent/'candidate/rtl/core/core.sv').read_text()
    changed = patch.transform(core,(parent/'candidate'/TARGET).read_text())
    assert changed == (leaf/'core_mem_chain.svh').read_text()
    flags = next(s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions = re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions) == len(set(definitions)) == 150 and '--assert' in flags
    assert 'VL_J=32' in before['command'] and not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT','VEN_FP_LOAD_EARLY_CMD','VEN_RAW_V_READ_PRIME'} <= set(definitions)
    for path in (Path(__file__),Path(patch.__file__),Path(common.__file__),
                 REPO/'verif/l1/build_mc_branch_residency_core.py',
                 parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
                 leaf/'closed.json',formal/'closed.json'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    root.mkdir(); shutil.copytree(parent/'candidate',root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    relative = [str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(parent/'candidate'/p) != sha(root/'candidate'/p)] == [TARGET]
    host = root/('tb_mc_read_commit_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(before['host'],host)
    command = common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    prepared = dict(command=command,pins=pins,host=str(host),parent=str(parent),
        parent_model=MODEL,changes=[TARGET],definitions=definitions,compiler_started=False,
        canonical_gate_passed=False,gameplay_ipc=None)
    save(root/'prepared.json',prepared)
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    save(root/'build-started.json',dict(prepared,compiler_started=True,
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False,errors=[],canonical_gate_passed=False,gameplay_ipc=None,
                  standard_suite=False,hardware_acceptance=False)
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=660)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(pins),seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
