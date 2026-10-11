#!/usr/bin/env python3
"""Source-match the four-file FP read-ACK split to a private posted-16 PC model."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def load(p):
    return json.loads(p.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('parent','proof','out'):
        ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    parent=args.parent.resolve(strict=True); proof=args.proof.resolve(strict=True)
    root=args.out.resolve(); core=proof/'core-r1'
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.is_relative_to(parent)
    assert Path(os.environ['TMPDIR']).resolve()==root and shutil.disk_usage(scratch).free>4*1024**3
    prior=load(parent/'build-started.json'); closed=load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']=='32beddd8035cb335123411e450ee645ed4ff03dddc6a4794685140cc24549b16'
    audit=load(proof/'audit.json')
    assert audit['audit_complete'] and audit['all_20_canonical_cycle_streams_identical']
    assert audit['counts']==dict(cases=156,architectural_records=75192,targeted_memory_v=1500,agi_accepts=350)
    assert not audit['canonical_gate_passed']
    assert audit['fragment_cases']==48 and audit['fragment_records']==141510
    assert audit['fault_cases']==16 and audit['fault_records']==23585
    assert sha(core/'obj/tb_ventium')==audit['model_sha256']=='b5554a977cd1ef4f12ee4a55a92fa514608cc902178aec2060a71fd00537e442'
    pins=prior['pins']|audit['pins']
    assert all(sha(p)==h for p,h in pins.items())
    changes=sorted(['rtl/core/core.sv','rtl/ventium_top.sv','rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv']); shared=[]
    for group in ('rtl','fp_shared'):
        for p in (parent/'source'/group).rglob('*'):
            rel=p.relative_to(parent/'source'); q=core/'candidate'/rel
            if p.is_file() and q.is_file():
                shared.append(str(rel))
                if str(rel) not in changes: assert sha(p)==sha(q),str(rel)
    assert len(shared)==102
    root.mkdir()
    shutil.copytree(parent/'source',root/'source')
    for rel in changes:
        shutil.copyfile(core/'candidate'/rel,root/'source'/rel)
    observed=sorted(str(p.relative_to(root/'source')) for p in (root/'source').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'source'/p.relative_to(root/'source')))
    assert observed==changes and all(sha(root/'source'/rel)==sha(core/'candidate'/rel) for rel in shared)
    hosts=[Path(s) for s in prior['command'] if s.startswith(str(parent/'source/ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    oldhost=hosts[0]; host=root/'source/ao486-sim/ven'/('sim_fp_read_ack_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost,host)
    command=[s.replace(str(parent),str(root)) for s in prior['command']]
    command=[str(host) if s.endswith('/'+oldhost.name) else s for s in command]
    defs=lambda cmd:set(s[2:] for s in cmd if s.startswith('-D'))|set(s[8:] for s in cmd if s.startswith('+define+'))
    assert defs(command)==defs(prior['command']) and len(defs(command))==154
    with (root/'defines.txt').open('x') as f:
        f.write('\n'.join(sorted(defs(command)))+'\n')
    def warnings(text):
        return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$',text,re.M))
    expected=warnings((parent/'build.log').read_text()); assert sum(expected.values())==98
    for p in (root/'source').rglob('*'):
        if p.is_file(): pins[str(p)]=sha(p)
    for p in (Path(__file__),root/'defines.txt',parent/'build-started.json',parent/'build-closed.json',
              parent/'build.log',proof/'audit.json',core/'build-closed.json'):
        pins[str(p)]=sha(p)
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    save('build-started.json',dict(command=command,pins=pins,changes=changes,added_defines=[],
        intersecting_rtl_sources=shared,parent_model=closed['binary_sha256'],directed_model=audit['model_sha256'],
        canonical_gate_passed=False,invocation=os.environ.get('INVOCATION_ID')))
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result=dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False,qualification='UNQUALIFIED')
    begin=time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            p=subprocess.run(command,cwd=root/'source',env=env,stdout=f,stderr=subprocess.STDOUT,timeout=660)
        result['native_exit']=p.returncode
        got=warnings((root/'build.log').read_text()); assert got==expected,(got-expected,expected-got)
        result.update(structural_warnings_unchanged=True,structural_debt_count=98)
        assert p.returncode==0
        obj=root/'obj1-speed-q16-parentpolicy'; assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split() if Path(s).name=='Vsystem___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vsystem___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'ao486sim_board_posted'),harness_header=str(header))
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(inputs_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
        result['passed'] &= result['inputs_unchanged']; save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
