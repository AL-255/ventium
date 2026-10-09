#!/usr/bin/env python3
"""Bounded private full-system build; does not run a guest or start Vivado."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

REPO=Path(__file__).resolve().parents[1]


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('prepared',type=Path)
    ap.add_argument('--profile',type=int,choices=(0,1),required=True)
    ap.add_argument('--host-opt',choices=('size','speed'),default='speed',
                    help='Host compiler only; never changes guest RTL clocks')
    args=ap.parse_args()
    root=args.prepared.resolve(strict=True);src=root/'source'
    meta=json.loads((root/'prepared.json').read_text())
    slots=meta.get('write_slots',8)
    assert slots in (4,8,16)
    tag=f'{args.profile}-{args.host_opt}-q{slots}'
    obj=root/f'obj{tag}'
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    assert not obj.exists(), 'new object directory required'
    assert os.statvfs(root).f_bavail*os.statvfs(root).f_frsize>6*1024**3
    assert meta['qualification']=='UNBUILT_EXPERIMENTAL_BOARD_TRANSPORT_SIM'
    # Inventory for pins only. Compilation uses the two explicit RTL filelists.
    names=subprocess.check_output(['rg','--files','-uuu',str(src)],text=True).splitlines()
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    pins={name:digest(Path(name)) for name in names}
    pins[str(root/'defines.txt')]=digest(root/'defines.txt')
    pins[str(Path(__file__).resolve())]=digest(Path(__file__).resolve())
    defs=(root/'defines.txt').read_text().splitlines()
    assert len(defs)==111 and defs[-1]=='VEN_DDR_POSTED'
    exe='ao486sim_board_posted' if args.profile else 'ao486sim_board_serial'
    cflags=f'-std=c++17 -DVEN_BOARD_POSTED_PROFILE={args.profile} -DVEN_BOARD_WRITE_SLOTS={slots} -I{src}/ao486-sim/ps -I{src}/ao486-sim/ven'
    # Verilator's makefile appends OPT_FAST after user CFLAGS: passing -O2
    # through CFLAGS alone is silently overridden by its default -Os.
    host_flags=['-MAKEFLAGS','OPT_FAST=-O3','-MAKEFLAGS','OPT=-march=native'] if args.host_opt=='speed' else []
    slot_flags=[f'-GBOARD_WRITE_SLOTS={slots}'] if 'write_slots' in meta else []
    command=[str(REPO/'tools/build_scope.sh'),'--','timeout','--signal=TERM','--kill-after=15s','900s',
        'verilator','--cc','--exe','--build','-j','32','--threads','1','--savable',
        '--output-groups','0','--output-split','3000','--output-split-cfuncs','3000',
        '--top-module','system','-O3','-Wall','-Wno-UNUSED','-Wno-fatal',
        f'-GBOARD_POSTED={args.profile}',*slot_flags,'--Mdir',str(obj),'-o',exe,'-CFLAGS',cflags,'-LDFLAGS','-lz',*host_flags,
        '-I'+str(src/'ao486-sim/ven'),*['-D'+d for d in defs],
        '-f','rtl_ven_core.f','-f','rtl_ven_soc.f',
        'ao486-sim/ven/ven_ao486_shim.sv','ao486-sim/ven/ven_axi2avalon.sv',
        'fpga/ven_ddram_axi.v','fpga/ven_ddram_axi_posted.sv',
        str(src/'ao486-sim/ven/sim_board_transport.cpp'),str(src/'ao486-sim/ven/vtm_dpi.cpp'),
        str(src/'ao486-sim/ps/ps_shim.cpp'),str(src/'ao486-sim/ps/ide.cpp'),str(src/'ao486-sim/ps/support/x86/x86.cpp')]
    started=dict(command=command,cwd=str(src),pins=pins,profile=args.profile,write_slots=slots,host_opt=args.host_opt,started=time.time(),
                 native_jobs=32,memory_limit='16G',runtime_limit_seconds=900)
    with (root/f'build{tag}-started.json').open('x') as out:
        out.write(json.dumps(started,indent=2)+'\n')
    env=dict(os.environ,TMPDIR='/home/yukidama/external/tmp',CCACHE_DISABLE='1',
             VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32')
    with (root/f'build{tag}.log').open('x') as log:
        p=subprocess.run(command,cwd=src,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=930)
    unchanged=all(digest(Path(name))==sha for name,sha in pins.items())
    receipt=dict(returncode=p.returncode,inputs_unchanged=unchanged,finished=time.time(),
                 binary_sha256=digest(obj/exe) if p.returncode==0 else None,
                 guest_acceptance=False,gameplay_ipc=None)
    if p.returncode==0:
        dependency=(obj/'sim_board_transport.d').read_text()
        assert 'Vsystem___024root.h' in dependency and (obj/'sim_board_transport.o').is_file()
    with (root/f'build{tag}-closed.json').open('x') as out:
        out.write(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt),flush=True)
    assert unchanged and p.returncode==0,root/f'build{tag}.log'


if __name__=='__main__':main()
