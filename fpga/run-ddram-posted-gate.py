#!/usr/bin/env python3
"""Bounded microgate for the unselected posted DDR bridge prototype.

Pass --baseline the immutable installed-image ven_ddram_axi.v, not an arbitrary
live external checkout. No Vivado, board access, or full-system guest is started.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    args = ap.parse_args()
    base = args.baseline.resolve(strict=True)
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert os.statvfs(scratch).f_bavail * os.statvfs(scratch).f_frsize > 2*1024**3
    root = Path(tempfile.mkdtemp(prefix='ventium-ddram-posted.', dir=scratch))
    sources = [base, REPO/'fpga/ven_ddram_axi_posted.sv',
               REPO/'fpga/ven_ddram_axi_throughput_tb.sv', REPO/'fpga/tb_ddram_posted.cpp', Path(__file__).resolve()]
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    pins = {str(p):digest(p) for p in sources}
    (root/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    print(root, flush=True)

    def command(argv, label, expected=0):
        p = subprocess.run(list(map(str,argv)),cwd=REPO,capture_output=True,text=True,timeout=150)
        (root/(label+'.log')).write_text(p.stdout+p.stderr)
        if expected == 0:
            assert p.returncode==0, (label,p.returncode,p.stdout[-1000:],p.stderr[-1000:])
        else:
            assert p.returncode!=0, 'negative control unexpectedly passed'
        return p.stdout+p.stderr

    command([REPO/'tools/build_scope.sh','--','timeout','120','verilator','--cc','--exe','--build','-j','1',
             '--top-module','ven_ddram_axi_posted','--Mdir',root/'obj','-o','fuzz',
             '-Wall','-Wno-UNUSED','-Wno-fatal','-Werror-IMPLICIT','-Werror-PINMISSING',
             '-Werror-UNDRIVEN','-Werror-MULTIDRIVEN','-Werror-LATCH','-Werror-UNOPTFLAT',
             sources[1],sources[3]],'build')
    with ThreadPoolExecutor(max_workers=32) as pool:
        results = list(pool.map(lambda seed: command([root/'obj/fuzz',seed],f'fuzz-{seed}'),range(1,33)))
    assert all('DDRAM-POSTED-FUZZ-OK' in text for text in results)

    def throughput(kind, latency, source=None):
        label=f'{kind}-{latency}'
        argv=['iverilog','-g2012','-s','ven_ddram_axi_throughput_tb',
              f'-Pven_ddram_axi_throughput_tb.B_LATENCY={latency}','-o',root/(label+'.vvp')]
        if kind!='baseline': argv+=['-DVEN_TEST_POSTED']
        command(argv+[source or (base if kind=='baseline' else sources[1]),sources[2]],label+'-build')
        text=command(['vvp',root/(label+'.vvp')],label,expected=1 if kind=='no-drain' else 0)
        if kind=='no-drain':
            assert 'read overtook uncommitted writes' in text
            return None
        match=re.search(r'DDRAM-THROUGHPUT-OK b_latency=(\d+) writes=(\d+) drained_cycles=(\d+)',text)
        assert match and int(match[1])==latency and int(match[2])==64
        return dict(profile=kind,b_latency=latency,writes=64,cycles=int(match[3]))

    with ThreadPoolExecutor(max_workers=32) as pool:
        rows=list(pool.map(lambda item: throughput(*item),
                  [(kind,latency) for kind in ('baseline','posted') for latency in (0,1,7,20,47)]))
    # Mutation test: the same scoreboard must reject a read issued before B.
    original=sources[1].read_text()
    old='DRAIN: if (occupied == 0 && !fault) st <= AR;'
    assert original.count(old)==1
    negative=root/'no-drain.sv'
    negative.write_text(original.replace(old,'DRAIN: if (!fault) st <= AR;'))
    throughput('no-drain',47,negative)
    assert all(digest(Path(p))==h for p,h in pins.items())
    receipt=dict(passed=True,source_pins=pins,random_seeds=32,
                 partial_alias_writes=81920,read_requests=5120,
                 negative_control='read-before-B rejected',throughput=rows,
                 gameplay_ipc=None,full_system_acceptance=False,installed=False)
    (root/'closed.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(dict(passed=True,evidence=str(root),throughput=rows)),flush=True)


if __name__=='__main__':
    main()
