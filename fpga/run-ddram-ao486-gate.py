#!/usr/bin/env python3
"""Frozen full memory-path gate; no FPGA build or guest image modification."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--inputs', type=Path, required=True)
    args = ap.parse_args()
    frozen = args.inputs.resolve(strict=True)
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert os.statvfs(scratch).f_bavail * os.statvfs(scratch).f_frsize > 2*1024**3
    root = Path(tempfile.mkdtemp(prefix='ventium-ddram-ao486.', dir=scratch))
    sources = [frozen/'ventium/rtl/mem/ven_axi_master.sv',
               frozen/'ventium/ao486-sim/ven/ven_axi2avalon.sv',
               frozen/'ventium/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v',
               REPO/'ao486-sim/stubs/sim_prims.sv',
               frozen/'flow/src/ven_ddram_axi.v',
               REPO/'fpga/ven_ddram_axi_posted.sv', REPO/'fpga/tb_ddram_ao486_path.sv']
    shim = REPO/'ao486-sim/ven/ven_ao486_shim.sv'
    pins = sources + [frozen/'defines.txt', Path(__file__).resolve(),shim]
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    hashes = {str(p): digest(p) for p in pins}
    # The generic altdpram stub declares eight unused optional vendor inputs;
    # the real L2 intentionally omits them. Specialize only that simulation
    # interface, not the cache RTL or model behavior, to keep PINMISSING fatal.
    prims = sources[3].read_text()
    first = prims.index('module altdpram #(')
    last = prims.index('endmodule',first)
    block = prims[first:last]
    for name in ('aclr','byteena','inclocken','outclocken','rdaddressstall',
                 'rden','sclr','wraddressstall'):
        assert len(re.findall(r'\b'+name+r'\b',block)) == 1
        block, count = re.subn(r',\n    input\s+'+name+r'(?=,|\n)', '', block)
        assert count == 1
    adapted = root/'sim_prims_l2.sv'
    adapted.write_text(prims[:first]+block+prims[last:])
    hashes[str(adapted)] = digest(adapted)
    sources[3] = adapted
    # The I/O/host-debug barrier in this test is the actual shim predicate.
    shim_text=shim.read_text()
    first=shim_text.index('`ifdef VEN_DDR_POSTED\n')
    last=shim_text.index('    // -------------------------------------------------------- A20',first)
    contract=root/'posted_ordering.svh'
    contract.write_text(shim_text[first:last])
    hashes[str(contract)]=digest(contract)
    (root/'inputs.json').write_text(json.dumps(hashes, indent=2)+'\n')
    defines = [line.strip() for line in (frozen/'defines.txt').read_text().splitlines()]
    # XPM is hardware-only; the same cache ports use the verified sim primitive.
    defines = [d for d in defines if d not in ('SYNTHESIS','VTM_NO_DPI','VEN_ALTSYNCRAM_XPM')]
    assert all(d in defines for d in ('VEN_AXI2AVL_WRITE_THROUGH','VEN_L2_STREAM_ANY',
                                     'VEN_P54_WBUF_PIPE_DISPATCH','VEN_AO486_SINGLE_FILL'))
    print(root, flush=True)

    def command(argv, label, build=False, negative=False):
        env = dict(os.environ)
        if build:
            env.update(VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',
                       VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32')
        p = subprocess.run(list(map(str, argv)), cwd=REPO, env=env,
                           capture_output=True, text=True, timeout=240 if build else 30)
        (root/(label+'.log')).write_text(p.stdout+p.stderr)
        assert (p.returncode != 0 if negative else p.returncode == 0), (label,p.returncode,(p.stdout+p.stderr)[-4000:])
        return p.stdout+p.stderr

    def build(posted,slots,tag,include):
        command([REPO/'tools/build_scope.sh','--','timeout','210','verilator',
                 '--binary','--timing','--assert','--build-jobs','32',
                 '--top-module','tb_ddram_ao486_path',f'-GPOSTED={posted}',f'-GWRITE_SLOTS={slots}',
                 '--Mdir',root/tag,'-o','test','-Wall','-Wno-UNUSED','-Wno-fatal',
                 '-Werror-IMPLICIT','-Werror-PINMISSING','-Werror-UNDRIVEN',
                 '-Werror-MULTIDRIVEN','-Werror-LATCH','-Werror-UNOPTFLAT',
                 '-DVEN_DDR_POSTED','-I'+str(include),
                 *['-D'+d for d in defines],*sources],tag+'-build',build=True)

    for posted, slots in ((0,8),(1,4),(1,8),(1,16)):
        build(posted,slots,f'p{posted}-q{slots}',root)

    def run(item):
        posted,slots,seed,latency=item
        tag=f'p{posted}-q{slots}'
        label=f'{tag}-s{seed}-b{latency}'
        out=command([root/tag/'test',f'+seed={seed}',f'+latency={latency}'],label)
        assert 'DDRAM-AO486-PATH-OK' in out
        match=re.search(r'DDRAM-AO486-THROUGHPUT .* clocks=(\d+) stores=64',out)
        assert match
        return dict(posted=posted,slots=slots,seed=seed,latency=latency,cycles=int(match[1]))

    with ThreadPoolExecutor(max_workers=32) as pool:
        rows=list(pool.map(run,[(p,q,s,l) for p,q in ((0,8),(1,4),(1,8),(1,16))
                               for s in range(1,33) for l in (0,7,20,47)]))
    negative=root/'early-io'; negative.mkdir()
    # Prove that an inner-only "idle" really is insufficient, rather than
    # trusting a passing barrier assertion with no outstanding-write coverage.
    (negative/'posted_ordering.svh').write_text('wire platform_memory_drained = v_m_idle;\n')
    build(1,8,'negative',negative)
    bad=command([root/'negative/test','+seed=1','+latency=47'],'early-io',negative=True)
    assert 'I/O/debug barrier overtook a core write' in bad or 'early I/O/debug release' in bad
    assert all(digest(Path(p))==h for p,h in hashes.items())
    receipt=dict(passed=True,source_pins=hashes,profiles=rows,
                 tests=len(rows),negative_control='inner-only I/O/debug drain rejected',
                 full_system_acceptance=False,installed=False,
                 gameplay_ipc=None)
    (root/'closed.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(dict(passed=True,tests=len(rows),evidence=str(root))),flush=True)


if __name__=='__main__':
    main()
