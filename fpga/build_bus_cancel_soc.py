#!/usr/bin/env python3
"""Source-matched PC build of bus cancellation independent of inactive payload.

Retain the posted-16 platform, all 154 native definitions and 102 shared RTL
sources. This diagnostic build does not qualify the canonical gate or FPGA.
"""
import argparse
from collections import Counter
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

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
from prepare_bus_cancel_payload import transform


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def load(p): return json.loads(p.read_text())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','proof','out'):
        parser.add_argument('--'+n,type=Path,required=True)
    parser.add_argument('--audit-sha256',required=True)
    args=parser.parse_args()
    parent,proof=args.parent.resolve(strict=True),args.proof.resolve(strict=True)
    root,core=args.out.resolve(),proof/'core-r1'
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>5*1024**3
    prior,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']=='ac55dafd6687b0778a4d8285198f8e1d4d91f990a0800c09c962979b9166b32b'
    audit_path=proof/'core-audit.json'
    assert re.fullmatch(r'[0-9a-f]{64}',args.audit_sha256) and sha(audit_path)==args.audit_sha256
    audit=load(audit_path)
    assert audit['audit_complete'] and audit['directed_regressions_passed']
    assert audit['all_20_canonical_cycle_streams_identical']
    assert audit['source_deltas']==['rtl/core/core_bus_driver.svh']
    assert {name:row['architectural_records'] for name,row in audit['directed'].items()}=={
        'system-r2':31748,'fp-r1/matrix':78048,'smm-r1':51160,'rep-smi-r1':652}
    assert audit['same_input_canonical_cases']==108
    assert audit['same_input_canonical_records']==80800
    assert sha(core/'obj/tb_ventium')==audit['model_sha256']=='f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'
    pins={**prior['pins'],**audit['pins']}
    assert all(sha(p)==h for p,h in pins.items())
    changes=['rtl/core/core_bus_driver.svh']
    assert (core/'candidate'/changes[0]).read_text()==transform((parent/'source'/changes[0]).read_text())
    shared=[]
    for group in ('rtl','fp_shared'):
        for p in (parent/'source'/group).rglob('*'):
            relative=p.relative_to(parent/'source')
            q=core/'candidate'/relative
            if p.is_file() and q.is_file():
                shared.append(str(relative))
                if str(relative) not in changes: assert sha(p)==sha(q),str(relative)
    assert len(shared)==102
    root.mkdir()
    shutil.copytree(parent/'source',root/'source')
    for relative in changes:
        shutil.copyfile(core/'candidate'/relative,root/'source'/relative)
    observed=sorted(str(p.relative_to(root/'source')) for p in (root/'source').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'source'/p.relative_to(root/'source')))
    assert observed==changes
    assert all(sha(root/'source'/p)==sha(core/'candidate'/p) for p in shared)
    hosts=[Path(s) for s in prior['command'] if s.startswith(str(parent/'source/ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    oldhost=hosts[0]
    host=root/'source/ao486-sim/ven'/('sim_bus_cancel_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost,host)
    command=[s.replace(str(parent),str(root)) for s in prior['command']]
    command=[str(host) if s.endswith('/'+oldhost.name) else s for s in command]
    def defs(cmd):
        return {s[2:] for s in cmd if s.startswith('-D')}|{s[8:] for s in cmd if s.startswith('+define+')}
    assert defs(command)==defs(prior['command']) and len(defs(command))==154
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs(command)))+'\n')
    def warnings(text):
        return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$',text,re.M))
    expected=warnings((parent/'build.log').read_text())
    assert sum(expected.values())==98
    pins.update({str(p):sha(p) for p in (root/'source').rglob('*') if p.is_file()})
    for p in (Path(__file__),REPO/'verif/issue_uv/prepare_bus_cancel_payload.py',root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              audit_path,core/'build-closed.json'):
        pins[str(p)]=sha(p)
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    save('build-started.json',dict(command=command,pins=pins,changes=changes,added_defines=[],
        intersecting_rtl_sources=shared,parent_model=closed['binary_sha256'],directed_model=audit['model_sha256'],
        canonical_gate_passed=audit['canonical_gate_passed'],invocation=os.environ['INVOCATION_ID']))
    env={**os.environ,'CCACHE_DISABLE':'1','PYTHONDONTWRITEBYTECODE':'1',
        'VENTIUM_BUILD_SCOPE_PROFILE':'ipc_parallel32','VENTIUM_BUILD_SCOPE_UNIT':'ventium-ipc-parallel32',
        'VENTIUM_VERILATOR_BIN':'/tools/verilator/v5.046/bin/verilator','TMPDIR':str(root)}
    result=dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False,qualification='UNQUALIFIED')
    begin=time.monotonic()
    try:
        with (root/'build.log').open('x') as log:
            child=subprocess.run(command,cwd=root/'source',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=660)
        result['native_exit']=child.returncode
        got=warnings((root/'build.log').read_text())
        assert got==expected,(got-expected,expected-got)
        result.update(structural_warnings_unchanged=True,structural_debt_count=98)
        assert child.returncode==0
        obj=root/'obj1-speed-q16-parentpolicy'
        assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vsystem___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vsystem___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'ao486sim_board_posted'),harness_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(inputs_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
    result['passed'] &= result['inputs_unchanged']
    save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
