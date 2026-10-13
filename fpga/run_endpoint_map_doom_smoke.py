"""Cold-boot the unmodified Doom disk on the frozen PC candidate, diagnostically.

Bounded startup coverage alongside synthesis, never FPGA/FPS/suite acceptance.
Do not restore a snapshot or change guest code. Native exit zero alone is not
a successful Doom timedemo. The original media and compiled inputs stay pinned.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time

import build_endpoint_map_soc as native
import prepare_endpoint_map_synthesis as timing

MEDIA=Path('/home/yukidama/external/tmp/ventium-doom-board.pqK32bcA').resolve(strict=True)
DISK='81d08c99c66ad08cf9578811381001c7c156b7b33a17ea34012c77a6018dd576'
EXE='b8020523561a5ad9706e009a52d61c578f37faafd85ac471962308406292ce27'
WAD='1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771'


def summary(text):
    """Observations only: no inferred success or performance from return code."""
    return dict(boot_sector_observed='[BOOT] reached boot sector' in text,
        dos_marker_observed=bool(re.search(r'^  \|DOOM_DEMO3_START\s*$',text,re.M)),
        returned_marker_observed=bool(re.search(r'^  \|DOOM_DEMO3_RETURNED\s*$',text,re.M)),
        invalid_opcode_observed=bool(re.search(r'^  \|.*Invalid Opcode',text,re.M|re.I)),
        native_error_observed=bool(re.search(r'%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED',text)),
        graphics_captures=len(re.findall(r'^\[FBCAP\]',text,re.M)))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    args=ap.parse_args();out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert out.parent==timing.ROOT and not out.exists() and os.sched_getaffinity(0)=={12}
    assert re.fullmatch(r'ventium-endpoint-map-doom-smoke-[a-z0-9-]+\.service',args.unit)
    assert os.environ['INVOCATION_ID']==subprocess.check_output(['systemctl','--user','show',args.unit,
        '-pInvocationID','--value'],text=True).strip()
    cgroup=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    assert (cgroup/'memory.max').read_text().strip()==str(512*1024**2)
    assert (cgroup/'memory.swap.max').read_text().strip()=='0'
    assert shutil.disk_usage(scratch).free>5*1024**3
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
    sha,load=native.sha,native.load
    pc=timing.ROOT/'endpoint-map-soc-r1'
    model=pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'
    closed=load(pc/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==sha(model)==timing.MODEL
    pins=dict(load(pc/'build-started.json')['pins'])
    rom=scratch/'ventium-sfetch16-soc.p8u2t1lA/quake-cold-sfetch16-oct10.1/run/rom'
    for p in (model,pc/'build-closed.json',Path(__file__),MEDIA/'doom-input.vhd',
              rom/'boot0.rom',rom/'boot1.rom'):
        pins[str(p)]=sha(p)
    assert pins[str(MEDIA/'doom-input.vhd')]==DISK and native.stable(pins)
    defs=set((pc/'defines.txt').read_text().splitlines())
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT'}<=defs
    assert not {'VEN_SYS_FASTPATH_ALL','VEN_CACHE_HALF'}&defs
    assert re.search(r'\.cycle_mode\s*\(1\x27b1\)',(pc/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text())
    out.mkdir();shutil.copytree(rom,out/'rom');shutil.copyfile(MEDIA/'doom-input.vhd',out/'doom.vhd')
    assert sha(out/'doom.vhd')==DISK
    for name,digest in (('DOOM.EXE',EXE),('DOOM1.WAD',WAD)):
        data=subprocess.check_output(['mtype','-i',str(out/'doom.vhd')+'@@32256','::DOOM/'+name])
        assert hashlib.sha256(data).hexdigest()==digest
    argv=[str(model),'--ide',str(out/'doom.vhd'),'--rate','40000000','--rate-rtc','40000000',
        '--rate-vga','80000000','--mem','16','--cycles','100000000','--ven-perf-every','1000000',
        '--vgatext-every','1000000','--fb-every','10000000','--fb-out',str(out/'frame')]
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','AO486_','AXI_','TB_'))}
    env.update(AO486_BIOS_DIR=str(out/'rom'),TMPDIR=str(out))
    native.save(out/'started.json',dict(pins=pins,argv=argv,model=timing.MODEL,
        invocation=os.environ['INVOCATION_ID'],unit=args.unit,core_hz=40000000,cold_reset=True,
        max_seconds=1800,max_cycles=100000000,diagnostic_only=True,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    child=None;reason=None;failure=None;start=time.monotonic();observed=None
    interrupted=[]
    signal.signal(signal.SIGTERM,lambda signum,frame:interrupted.append(signum))
    signal.signal(signal.SIGINT,lambda signum,frame:interrupted.append(signum))
    try:
        with (out/'run.log').open('x') as stream:
            child=subprocess.Popen(argv,cwd=out,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            proc=Path('/proc')/str(child.pid);deadline=time.monotonic()+3
            while (proc/'exe').resolve()!=model:
                assert child.poll() is None and time.monotonic()<deadline
                time.sleep(.01)
            observed=dict(pid=child.pid,exe=str((proc/'exe').resolve()),
                argv=[os.fsdecode(s) for s in (proc/'cmdline').read_bytes().split(b'\0')[:-1]],
                cgroup=(proc/'cgroup').read_text(),affinity=sorted(os.sched_getaffinity(child.pid)),
                starttime=(proc/'stat').read_text().rsplit(')',1)[1].split()[19])
            native.save(out/'native.json',observed)
            assert observed['argv']==argv and observed['affinity']==[12]
            assert observed['cgroup']==Path('/proc/self/cgroup').read_text()
            while child.poll() is None:
                if interrupted:reason='controller interrupted'
                elif time.monotonic()-start>1800:reason='diagnostic wall-time limit'
                elif shutil.disk_usage(out).free<4*1024**3:reason='disk reserve'
                if reason:break
                time.sleep(5)
    except BaseException as error:
        failure=repr(error)
    finally:
        if child is not None:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            else:child.wait()
    result=dict(native_exit=child.returncode if child else None,reason=reason,failure=failure,
        seconds=time.monotonic()-start,inputs_unchanged=native.stable(pins),
        child_reaped=child is not None and not (Path('/proc')/str(child.pid)).exists(),
        diagnostic_only=True,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fps=None)
    if (out/'run.log').exists():result['observations']=summary((out/'run.log').read_text(errors='replace'))
    result['memory_events']=dict(row.split() for row in (cgroup/'memory.events').read_text().splitlines())
    if child is not None and result['child_reaped']:
        extracted=subprocess.run(['mtype','-i',str(out/'doom.vhd')+'@@32256','::DOOM/DEMO3.LOG'],capture_output=True)
        with (out/'DEMO3.LOG').open('xb') as f:f.write(extracted.stdout)
        result['demo_log_native_exit']=extracted.returncode
        for name,digest in (('DOOM.EXE',EXE),('DOOM1.WAD',WAD)):
            data=subprocess.check_output(['mtype','-i',str(out/'doom.vhd')+'@@32256','::DOOM/'+name])
            assert hashlib.sha256(data).hexdigest()==digest
        result['guest_executable_and_wad_unchanged']=True
    result['artifacts']={p.name:sha(p) for p in out.iterdir() if p.is_file()}
    native.save(out/'closed.json',result);print(json.dumps(result,indent=2),flush=True)
    # Zero here means the diagnostic runner closed correctly, not that Doom passed.
    no_oom=all(result['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    return 0 if child and child.returncode==0 and not reason and not failure and result['inputs_unchanged'] and no_oom else 1


if __name__=='__main__':raise SystemExit(main())
