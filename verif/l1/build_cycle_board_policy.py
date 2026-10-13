"""Match the direct-core diagnostic's replay parameter to the ao486 shim.

No HDL/define/host changes; AXI_LINE_REPLAY=0 is the sole elaboration delta.
Does not change the default HP/HPC policy or program any hardware.
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

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
from build_mc_branch_residency_core import relocate
PARENT=Path('/home/yukidama/external/tmp/ventium-frndint.tM8XCg6d/core-r1')
MODEL='2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63'


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())
def save(p,d):
    with p.open('x') as f:json.dump(d,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(8,16)) and os.environ['INVOCATION_ID']
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    parent=PARENT.resolve(strict=True);old=load(parent/'build-started.json');built=load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    source=parent/'candidate';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert len(files)==195 and all(sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0]);assert len(set(definitions))==152
    assert 'VEN_AO486_SINGLE_FILL' in definitions and 'VEN_SINGLE_FILL' not in definitions
    shim=(source/'ao486-sim/ven/ven_ao486_shim.sv').read_text()
    assert "localparam bit AO486_LINE_REPLAY = 1'b0;" in shim
    assert 'ventium_top #(.AXI_LINE_REPLAY(AO486_LINE_REPLAY))' in shim
    pins=dict(old['pins'])
    for p in (Path(__file__),REPO/'verif/l1/build_mc_branch_residency_core.py',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir();shutil.copytree(source,root/'candidate')
    names=[str(p.relative_to(source)) for p in files]
    assert all(sha(source/n)==sha(root/'candidate'/n) for n in names)
    host=root/('tb_board_policy_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=relocate(old['command'],parent,root,Path(old['host']),host)
    index=next(i for i,s in enumerate(command) if s.startswith('VL_EXTRA_DEFINES='))
    assert '-GAXI_LINE_REPLAY' not in command[index]
    command[index]+=' -GAXI_LINE_REPLAY=0'
    pins[str(host)]=sha(host);pins.update({str(root/'candidate'/n):sha(root/'candidate'/n) for n in names})
    save(root/'build-started.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[],parameter_delta={'AXI_LINE_REPLAY':[1,0]},
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0)),
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    result=dict(passed=False,errors=[],canonical_gate_passed=False,standard_suite=False,
                hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    begin=time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            code=subprocess.run(command,env=dict(os.environ,CCACHE_DISABLE='1'),stdout=f,
                stderr=subprocess.STDOUT,timeout=540,pass_fds=(9,)).returncode
        result['native_exit']=code;assert code==0
        obj=root/'obj';assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split() if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1; header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        actual=(obj/'Vventium_top__verFiles.dat').read_text()
        assert actual.count('-GAXI_LINE_REPLAY=0')==1
        assert set(re.findall(r'\+define\+(\w+)',actual))==set(definitions)
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result);print(json.dumps(result,indent=2))
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
