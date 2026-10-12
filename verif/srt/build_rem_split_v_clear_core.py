#!/usr/bin/env python3
"""Compose the tested SRT input isolation and read-only V clear, then build.

Uses the exact measured 30.30487 MHz candidate, without editing it. No test,
synthesis, bitstream, or FPGA acceptance is implied by a successful compile.
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

import build_input_norm_core as common
import prepare_rem_operand_split as srt
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'l1'))
import prepare_v_owner_read_clear as clear

REPO=Path(__file__).resolve().parents[2]
MODEL='fbe7b4e3b31c83396414de6802fe2e06dd4be0d4b039199dfc0f8e660154c8d6'
sha,load,save,stable=common.sha,common.load,common.save,common.stable
TARGETS=sorted([*srt.HASHES,'rtl/core/core.sv'])


def definitions(command):
    flags=[s for s in command if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0]
    found=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(found)==len(set(found))==151
    assert {'VEN_FP_SHARED','VEN_FP_SHARED_DIRECT','VEN_FPREM','VEN_SRT_PAYLOAD_SELECT',
        'VEN_L1D_PAYLOAD_CODE_HINT','VEN_RAW_V_READ_PRIME','VEN_P54_DUAL_LOAD_PAIR',
        'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
        'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FP_LOAD_EARLY_CMD'} <= set(found)
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_P54_DUAL_LOAD_PRIME','VEN_P54_REGMEM_PRIME',srt.FLAG}&set(found)
    assert 'VL_J=32' in command
    return found+[srt.FLAG]


def proof_rows(result,expected):
    assert result['passed'] and result['pins_unchanged']
    assert [(r['label'],r['build_exit'],r['native_exit']) for r in result['rows']]==expected
    assert all(r['artifacts'] for r in result['rows'])


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','srt-leaf','clear-leaf','timing','out'):
        ap.add_argument('--'+name,required=True,type=Path)
    args=ap.parse_args()
    parent,engine,owner,timing=(getattr(args,k).resolve(strict=True) for k in ('parent','srt_leaf','clear_leaf','timing'))
    out=args.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    old,built=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    defs=definitions(old['command'])
    measured=load(timing/'audit.json')
    assert measured['passed'] and measured['native_exit']==0 and measured['constraints_mhz']==dict(core=40,pl=100)
    assert abs(measured['unplaced_core_estimate_mhz']-30.30486696163404)<1e-9
    assert measured['retained_owner']['InvocationID']=='96a978bfd1b5408cbbbd8952d504f67f'
    pins=dict(old['pins'],**measured['pins'])
    for folder,expected in ((engine,[('disabled',0,0),('enabled',0,0),('wrong-rem-port',0,1),('wrong-idle-carry',0,1)]),
                            (owner,[('positive',0,0),('raw-fragment-ack',0,1),('missing-read-ack',0,1),('lost-fault-clear',0,1)])):
        evidence=load(folder/'closed.json');proof_rows(evidence,expected)
        pins.update(evidence['pins'])
        for row in evidence['rows']:pins.update(row['artifacts'])
        pins[str(folder/'closed.json')]=sha(folder/'closed.json')
    assert 'SRT-REM-OPERAND-MITER-OK samples=4736 checks=165052 resets=24' in (engine/'enabled/run.log').read_text()
    assert 'PAIR-RESPONSE-LEAF-OK checks=77834 ' in (owner/'positive/run.log').read_text()
    source=parent/'candidate'
    changed=srt.transform({n:(source/n).read_text() for n in srt.HASHES})
    changed['rtl/core/core.sv']=clear.transform((source/'rtl/core/core.sv').read_text())
    for name in srt.HASHES:assert changed[name]==(engine/'candidate'/name).read_text()
    assert changed['rtl/core/core.sv']==(owner/'core.sv').read_text()
    files=common.candidate_files(source)
    assert len(files)==195 and all(sha(p)==old['pins'][str(p)] for p in files)
    for p in (Path(__file__),Path(srt.__file__),Path(clear.__file__),Path(common.__file__),
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',timing/'audit.json'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    out.mkdir();shutil.copytree(source,out/'candidate')
    for name,content in changed.items():(out/'candidate'/name).write_text(content)
    relative=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(out/'candidate')) for p in common.candidate_files(out/'candidate')]==relative
    assert [n for n in relative if sha(source/n)!=sha(out/'candidate'/n)]==TARGETS
    host=out/('tb_rem_split_v_clear_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=common.relocate(old['command'],parent,out,Path(old['host']),host)
    command=[s+' +define+'+srt.FLAG if s.startswith('VL_EXTRA_DEFINES=') else s for s in command]
    pins[str(host)]=sha(host)
    pins.update({str(out/'candidate'/n):sha(out/'candidate'/n) for n in relative})
    save(out/'build-started.json',dict(pins=pins,command=command,definitions=defs,
        host=str(host),parent=str(parent),parent_model=MODEL,changes=TARGETS,
        invocation=os.environ['INVOCATION_ID'],gameplay_ipc=None,canonical_gate_passed=False))
    begin=time.monotonic();result=dict(passed=False,errors=[],canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    try:
        with (out/'build.log').open('x') as log:
            native=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,
                env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=660)
        result['native_exit']=native.returncode;assert native.returncode==0
        obj=out/'obj';assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except BaseException as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=stable(pins))
    result['passed'] &= result['pins_unchanged']
    save(out/'build-closed.json',result);print(result,flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
