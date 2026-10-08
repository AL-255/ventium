#!/usr/bin/env python3
"""Check the host AXI BFM against serial and posted real RTL, 32 jobs each."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile

REPO=Path(__file__).resolve().parents[1]


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch==Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert os.statvfs(scratch).f_bavail*os.statvfs(scratch).f_frsize>2*1024**3
    root=Path(tempfile.mkdtemp(prefix='ventium-board-axi-memory.',dir=scratch))
    sources=[args.baseline.resolve(strict=True),REPO/'fpga/ven_ddram_axi_posted.sv',
             REPO/'ao486-sim/ven/board_axi_memory.h',REPO/'fpga/tb_board_axi_memory.cpp',Path(__file__).resolve()]
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    pins={str(p):digest(p) for p in sources}
    print(root,flush=True)
    def command(argv,label,build=False):
        p=subprocess.run(list(map(str,argv)),cwd=REPO,capture_output=True,text=True,timeout=150 if build else 30)
        (root/(label+'.log')).write_text(p.stdout+p.stderr)
        assert p.returncode==0,(label,p.returncode,(p.stdout+p.stderr)[-3000:])
        return p.stdout
    for serial in (False,True):
        name='serial' if serial else 'posted'
        module='ven_ddram_axi' if serial else 'ven_ddram_axi_posted'
        extra=['-CFLAGS','-DVEN_TEST_SERIAL_BRIDGE'] if serial else ['-GWRITE_SLOTS=8']
        command([REPO/'tools/build_scope.sh','--','timeout','120','verilator',
                 '--cc','--exe','--build','-j','1','--top-module',module,'--Mdir',root/name,'-o','test',
                 '-Wall','-Wno-UNUSED','-Wno-fatal','-Werror-IMPLICIT','-Werror-PINMISSING',
                 '-Werror-UNDRIVEN','-Werror-MULTIDRIVEN','-Werror-LATCH','-Werror-UNOPTFLAT',
                 *extra,sources[0 if serial else 1],sources[3]],name+'-build',True)
        with ThreadPoolExecutor(max_workers=32) as pool:
            rows=list(pool.map(lambda seed:command([root/name/'test',seed],f'{name}-{seed}'),range(1,33)))
        assert all('BOARD-AXI-MEMORY-OK' in x for x in rows)
    assert all(digest(Path(p))==h for p,h in pins.items())
    (root/'closed.json').write_text(json.dumps(dict(passed=True,source_pins=pins,
        models=['frozen serial','candidate eight slots'],seeds_per_model=32,
        write_latencies=[0,1,20,47],partial_writes=262144,read_requests=32768,
        full_system_acceptance=False,gameplay_ipc=None),indent=2)+'\n')
    print('BOARD-AXI-MEMORY-GATE-OK '+str(root))


if __name__=='__main__':main()
