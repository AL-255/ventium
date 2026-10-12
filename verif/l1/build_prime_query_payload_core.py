#!/usr/bin/env python3
"""Prepare/build the exact load-ACK derivative after its query-payload proofs.

Preparation is light and does not launch tools. Build requires the exclusive
32-job guard and no Vivado family. No flags, requests or latencies change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import prepare_prime_query_payload as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/srt'))
import build_input_norm_core as common

MODEL = '6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc'
sha,load,save,stable = common.sha,common.load,common.save,common.stable


def prepare(args, root):
    parent,leaf,proof = [getattr(args,key).resolve(strict=True) for key in ('parent','leaf','proof')]
    assert not root.exists()
    before,built = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    checked,proven = load(leaf/'closed.json'),load(proof/'closed.json')
    assert checked['passed'] and checked['pins_unchanged']
    assert proven['passed'] and proven['pins_unchanged'] and proven['abstract_combinational_contract']
    assert [(r['label'],r['native_exit']) for r in checked['rows']] == [
        ('positive',0),('always-live',1),('always-retained',1),('wrong-query-width',1),('lost-agi-width',1)]
    assert [(r['mode'],r['answer']) for r in proven['rows']] == [
        ('positive','unsat'),('idle-difference','sat'),('always-live','sat'),
        ('always-retained','sat'),('wrong-query-width','sat'),('lost-agi-width','sat'),
        ('allow-live-retained-collision','sat')]
    pins = {**before['pins'],**proven['pins']}
    for row in proven['rows']:
        for extension,key in (('.smt2','query_sha256'),('.log','log_sha256')):
            path = proof/(row['mode']+extension)
            assert sha(path) == row[key]
            pins[str(path)] = row[key]
    source = parent/'candidate'; files = common.candidate_files(source)
    assert len(files) == 195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changed = recipe.transform((source/recipe.PAYLOAD).read_text())
    assert changed == (leaf/'core_mem_chain.svh').read_text()
    flags = [s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions = re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME'} <= set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'} & set(definitions)
    for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(common.__file__).resolve(),
                 REPO/'verif/l1/build_mc_branch_residency_core.py',parent/'obj/tb_ventium',
                 parent/'build-started.json',parent/'build-closed.json',leaf/'closed.json',proof/'closed.json'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.PAYLOAD).write_text(changed)
    relative = [str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in common.candidate_files(root/'candidate')] == relative
    assert [p for p in relative if sha(source/p)!=sha(root/'candidate'/p)] == [recipe.PAYLOAD]
    host = root/('tb_prime_query_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'],host)
    command = common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)] = sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.PAYLOAD],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print(json.dumps(dict(prepared=str(root),files=len(relative),compiler_started=False)),flush=True)


def build(root):
    before = load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    assert stable(before['pins'])
    parent = Path(before['parent']); old = load(parent/'build-started.json')
    assert before['parent_model']==MODEL and before['changes']==[recipe.PAYLOAD]
    assert before['command']==common.relocate(old['command'],parent,root,Path(old['host']),Path(before['host']))
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
        result['native_exit']=native.returncode
        assert native.returncode==0
        obj,host = root/'obj',Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=stable(before['pins']))
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    for key in ('parent','leaf','proof'): ap.add_argument('--'+key,type=Path)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert all((args.parent,args.leaf,args.proof))
        prepare(args,root); return 0
    return build(root)


if __name__=='__main__': raise SystemExit(main())
