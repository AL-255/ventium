#!/usr/bin/env python3
"""Build a private response-cut derivative after Vivado's actual closure.

Requires the compiled read-hint parent and actual source-extracted recipe tests;
leaves all 150 defines and all other source bytes unchanged. No gate is waived.
"""
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

import prepare_pair_response_read_commit as patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import build_bus_cancel_core as common

MODEL = '64dadfc92c708c49d45e8c0f3b7704e1c24dff48f8d525956dc4624946a07695'
HEADER = 'fd0325d25511950f6761e73f3b2b9ce6ea8ec81c38692203b048954de65ecd5c'
TARGET = 'rtl/core/core.sv'
sha,save,load,stable = common.sha,common.save,common.load,common.stable


def check_rows(checked, proof):
    assert checked['passed'] and checked['pins_unchanged']
    assert proof['passed'] and proof['pins_unchanged'] and proof['abstract_proof']
    assert [(r['label'],r['native_exit']) for r in checked['rows']] == [
        ('positive',0),('missing-read-ack',1),('raw-fragment-ack',1),
        ('lost-orphan-drain',1),('lost-fault-clear',1)]
    assert [(r['label'],r['native_exit']) for r in checked['guard_rows']] == [
        ('raw',0),('nonraw',0),('dualprime',0),('regmem',0)]
    assert [(r['case'],r['native_exit'],r['answer']) for r in proof['rows']] == [
        ('owner-reset',0,'unsat'),('owner-induction',0,'unsat'),('read-consumer',0,'unsat'),
        ('store-owner-mutant',0,'sat'),('lost-completion-clear-mutant',0,'sat'),
        ('lost-fault-clear-mutant',0,'sat'),('missing-read-ack-mutant',0,'sat'),
        ('raw-fragment-ack-mutant',0,'sat'),('lost-orphan-drain-mutant',0,'sat')]
    log = checked['rows'][0]['log']
    assert not re.search(r'FATAL|ERROR|FAIL|mismatch',log)
    counts = re.search(r'PAIR-RESPONSE-LEAF-OK checks=(\d+) owned=(\d+) waits=(\d+) '
                       r'stores=(\d+) orphans=(\d+) accepts=(\d+)',log)
    assert counts
    checks,owned,waits,stores,orphans,accepts = map(int,counts.groups())
    assert checks>=77000 and owned>=4096 and waits>=1000 and stores and orphans and accepts>=4096


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','formal','out'):
        ap.add_argument('--'+name,required=True,type=Path)
    args=ap.parse_args()
    parent,leaf,formal=[getattr(args,n).resolve(strict=True) for n in ('parent','leaf','formal')]
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    before,built=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==sha(parent/'obj/tb_ventium')==MODEL
    assert sha(parent/'candidate/rtl/core/core_mem_chain.svh')==HEADER
    checked,proof=load(leaf/'closed.json'),load(formal/'closed.json')
    check_rows(checked,proof)
    pins={**before['pins'],**checked['pins'],**proof['pins']}
    for row in checked['rows']+checked['guard_rows']+proof['rows']:
        pins.update(row['artifacts'])
    for row in checked['rows']:
        assert (leaf/row['label']/'run.log').read_text()==row['log']
    files=common.candidate_files(parent/'candidate')
    assert len(files)==195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changed=patch.transform((parent/'candidate'/TARGET).read_text())
    assert changed==(leaf/'core.sv').read_text()
    assert checked['candidate_sha256']==sha(leaf/'core.sv')
    flags=next(s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES='))
    definitions=re.findall(r'\+define\+(\w+)',flags)
    assert len(definitions)==len(set(definitions))==150 and '--assert' in flags
    assert 'VL_J=32' in before['command']
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_P54_DUAL_LOAD_PRIME','VEN_P54_REGMEM_PRIME'} & set(definitions)
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME','VEN_P54_DUAL_LOAD_PAIR',
            'VEN_FP_LOAD_EARLY_CMD'} <= set(definitions)
    for path in (Path(__file__),Path(patch.__file__),Path(common.__file__),
                 REPO/'verif/l1/build_mc_branch_residency_core.py',
                 parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
                 leaf/'closed.json',leaf/'core.sv',formal/'closed.json'):
        pins[str(path)]=sha(path)
    assert stable(pins)
    root.mkdir(); shutil.copytree(parent/'candidate',root/'candidate')
    (root/'candidate'/TARGET).write_text(changed)
    relative=[str(p.relative_to(parent/'candidate')) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')]==relative
    assert [p for p in relative if sha(parent/'candidate'/p)!=sha(root/'candidate'/p)]==[TARGET]
    host=root/('tb_pair_response_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(before['host'],host)
    command=common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)]=sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    prepared=dict(command=command,pins=pins,host=str(host),parent=str(parent),parent_model=MODEL,
        changes=[TARGET],definitions=definitions,compiler_started=False,canonical_gate_passed=False,gameplay_ipc=None)
    save(root/'prepared.json',prepared)
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    save(root/'build-started.json',dict(prepared,compiler_started=True,
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    result=dict(passed=False,errors=[],canonical_gate_passed=False,gameplay_ipc=None,
                standard_suite=False,hardware_acceptance=False)
    start=time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=660)
        result['native_exit']=native.returncode
        assert native.returncode==0
        obj=root/'obj'; assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(pins_unchanged=stable(pins),seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
