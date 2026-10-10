#!/usr/bin/env python3
"""Transfer the checked legacy-capture cofactor into a private full-PC model."""
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
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def load(p):return json.loads(p.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('parent','core','leaf','out'):ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    root=args.out.resolve(strict=True); parent=args.parent.resolve(strict=True)
    core=args.core.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not any(root.iterdir())
    assert not root.is_relative_to(parent) and not parent.is_relative_to(root)
    assert Path(os.environ['TMPDIR']).resolve()==root and shutil.disk_usage(root).free>4*1024**3
    prior=load(parent/'build-started.json'); closed=load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']=='cf1b3b0bf30d35993c12f335c148dbf5c1ae90f09c0e26f3c2b22907263ab27c'
    coreclose=load(core/'build-closed.json'); lclose=load(leaf/'closed.json')
    assert coreclose['passed'] and coreclose['pins_unchanged'] and coreclose['native_exit']==0
    assert sha(core/'obj/tb_ventium')==coreclose['binary_sha256']=='de02d77f297f713adfc885c911006e7a7c427fa4113532183ba7e1160b3026a5'
    assert lclose['passed'] and lclose['pins_unchanged'] and len(lclose['rows'])==4
    verification=load(core/'verify-closed.json')
    audit=load(core/'audit.json')
    assert verification['pins_unchanged'] and audit['audit_complete']
    assert audit['all_20_canonical_cycle_streams_identical'] and audit['all_input_images_identical']
    assert audit['identical_state_records']==198816 and audit['underfill_samples']==228304
    # Record the existing failing authority honestly; do not relabel a baseline
    # failure as a pass to export a timing experiment.
    assert not verification['canonical_gate_passed'] and verification['canonical_gate_native_exit']==2
    pins=prior['pins']|load(core/'build-started.json')['pins']|load(leaf/'pins.json')
    for name,cases in (('prefix-system',384),('memory-system',72)):
        started=load(core/name/'started.json'); result=load(core/name/'closed.json')
        assert result['passed'] and result['pins_unchanged'] and not result['errors']
        assert len(result['measurements'])==cases*4
        pins.update(started['pins'])
    assert load(core/'memory-system/closed.json')['memory_v_retirements']==1500
    assert all(sha(p)==h for p,h in pins.items())
    changes=['rtl/mem/ven_l1d.sv']; shared=[]
    for group in ('rtl','fp_shared'):
        for p in (parent/'source'/group).rglob('*'):
            rel=p.relative_to(parent/'source'); q=core/'candidate'/rel
            if p.is_file() and q.is_file():
                shared.append(str(rel))
                if str(rel) not in changes:assert sha(p)==sha(q),str(rel)
    assert len(shared)==102
    shutil.copytree(parent/'source',root/'source')
    for rel in changes:shutil.copyfile(core/'candidate'/rel,root/'source'/rel)
    observed=sorted(str(p.relative_to(root/'source')) for p in (root/'source').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'source'/p.relative_to(root/'source')))
    assert observed==changes
    assert all(sha(root/'source'/rel)==sha(core/'candidate'/rel) for rel in shared)
    oldhost=parent/'source/ao486-sim/ven/sim_prefix_regonly_mmowhswi.cpp'
    host=root/'source/ao486-sim/ven'/('sim_l1_capture_'+root.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost,host)
    command=[s.replace(str(parent),str(root)) for s in prior['command']]
    command=[str(host) if s.endswith('/'+oldhost.name) else s for s in command]
    defs=lambda cmd:set(s[2:] for s in cmd if s.startswith('-D'))|set(s[8:] for s in cmd if s.startswith('+define+'))
    assert defs(command)==defs(prior['command']) and len(defs(command))==154
    with (root/'defines.txt').open('x') as f:f.write('\n'.join(sorted(defs(command)))+'\n')
    def warnings(text):return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$',text,re.M))
    expected=warnings((parent/'build.log').read_text()); assert sum(expected.values())==98
    for p in (root/'source').rglob('*'):
        if p.is_file():pins[str(p)]=sha(p)
    proof=[core/n for n in ('audit.json','build-started.json','build-closed.json','verify-started.json','verify-closed.json',
                           'prefix-system/started.json','prefix-system/closed.json',
                           'memory-system/started.json','memory-system/closed.json')]
    for p in (Path(__file__),root/'defines.txt',parent/'build-started.json',parent/'build-closed.json',
              parent/'build.log',leaf/'closed.json',leaf/'pins.json',*proof):pins[str(p)]=sha(p)
    def save(n,v):
        with (root/n).open('x') as f:json.dump(v,f,indent=2);f.write('\n')
    save('build-started.json',dict(command=command,pins=pins,changes=changes,added_defines=[],
        intersecting_rtl_sources=shared,parent_model=closed['binary_sha256'],directed_model=coreclose['binary_sha256'],
        canonical_gate_passed=False,invocation=os.environ.get('INVOCATION_ID')))
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result=dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False,qualification='UNQUALIFIED')
    start=time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            p=subprocess.run(command,cwd=root/'source',env=env,stdout=f,stderr=subprocess.STDOUT,timeout=660)
        result['native_exit']=p.returncode
        got=warnings((root/'build.log').read_text());assert got==expected,(got-expected,expected-got)
        result.update(structural_warnings_unchanged=True,structural_debt_count=98)
        assert p.returncode==0
        obj=root/'obj1-speed-q16-parentpolicy';assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split() if Path(s).name=='Vsystem___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vsystem___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'ao486sim_board_posted'),harness_header=str(header))
    except Exception as error:result['errors'].append(repr(error))
    finally:
        result.update(inputs_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
        result['passed'] &= result['inputs_unchanged'];save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
