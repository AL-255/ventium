#!/usr/bin/env python3
"""Bounded read-command A/B; exact same reads, widths, response owners and writes."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from run_l2_capacity import tie_unused_primitive_inputs

REPO = Path(__file__).resolve().parents[2]
def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True, help='frozen parent SoC source root')
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert args.out.resolve().is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    args.out.mkdir()
    original = args.source / 'ao486-sim/ven/ven_axi2avalon.sv'
    candidate = REPO / 'ao486-sim/ven/ven_axi2avalon.sv'
    sources = dict(control=original, candidate=candidate,
        focused=REPO/'verif/l1/tb_axi_read_through.sv',
        wrap=REPO/'ao486-sim/ven/tb_axi2avalon.sv',
        l2=args.source/'3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v',
        prims=args.source/'ao486-sim/stubs/sim_prims.sv')
    pins = {str(p):sha(p) for p in (*sources.values(), Path(__file__),
        REPO/'verif/l1/run_l2_capacity.py', REPO/'verif/l1/prepare_l2_capacity.py')}
    frozen = {}
    for name, path in sources.items():
        target = args.out / (name + path.suffix)
        text = path.read_text()
        if name == 'l2': text = tie_unused_primitive_inputs(text, sources['prims'].read_text())
        with target.open('x') as stream: stream.write(text)
        frozen[name] = target
        pins[str(target)] = sha(target)
    # The legacy real-L2 fixture starts with RESET already asserted and lets
    # unknown pre-reset cache commands reach its DDR model. With randomized
    # initialization, the L2's two reset synchronizers can both begin high,
    # missing its edge-triggered START walk. Supply a real low->high reset
    # transition, and admit NEW DDR commands only after cold reset and while
    # the outer bridge would be released. Already accepted DDR bursts still
    # survive all later resets, exactly as in the original fixture.
    text = sources['wrap'].read_text()
    anchors = {
        '  int tick = 0;': '  logic platform_started = 0;\n  int tick = 0;',
        '    if (ddr_rd && !av_active) begin':
            '    if (platform_started && rst_n && ddr_rd && !av_active) begin',
        '    if (ddr_we && !av_active) begin':
            '    if (platform_started && rst_n && ddr_we && !av_active) begin',
        "    repeat (4) @(posedge clk);\n    @(negedge clk); rst_n = 1'b1;":
            "    rst_n = 1'b1;\n    repeat (3) @(negedge clk);\n"
            "    rst_n = 1'b0;\n    repeat (4) @(negedge clk);\n"
            "    rst_n = 1'b1; platform_started = 1'b1;",
    }
    for old,new in anchors.items():
        assert text.count(old)==1,old
        text=text.replace(old,new)
    text=text.replace('if (rst_n &&', 'if (platform_started && rst_n &&')
    frozen['real']=args.out/'real_fixture.sv'
    with frozen['real'].open('x') as stream:stream.write(text)
    pins[str(frozen['real'])]=sha(frozen['real'])
    save(args.out/'pins.json', pins)
    tasks = []
    for profile, features in (('plain',[]), ('bpipe',['VEN_AXI2AVL_BPIPE']),
            ('write',['VEN_AXI2AVL_BPIPE','VEN_AXI2AVL_WRITE_THROUGH'])):
        for mode, source, extra in (('control','control',[]),('off','candidate',[]),
                ('on','candidate',['VEN_AXI2AVL_READ_THROUGH'])):
            for suite in ('focused','wrap'):
                tasks.append((profile+'-'+mode+'-'+suite,source,suite,features+extra))
    for mode, source, extra in (('control','control',[]),('off','candidate',[]),
            ('on','candidate',['VEN_AXI2AVL_READ_THROUGH'])):
        tasks.append(('real-'+mode,source,'real',
            ['VEN_AXI2AVL_BPIPE','VEN_AXI2AVL_WRITE_THROUGH','VEN_L2_STREAM_CWF',
             'VEN_L2_STREAM_ANY','VEN_ALTSYNCRAM_XPM',*extra]))
    def run(task):
        name, source, suite, features = task
        out = args.out/name;out.mkdir()
        top = 'tb_axi_read_through' if suite=='focused' else 'tb_axi2avalon'
        files = [frozen[source],frozen[suite]]
        if suite=='real':
            features += ['VEN_BRIDGE_REAL_L2'];files += [frozen['l2'],frozen['prims']]
        command = ['/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert',
            '-sv','-j','8','-Wall','-Wno-fatal','-Wno-UNUSED',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '+define+VEN_AXI2AVL_ASSERT',*['+define+'+f for f in features],
            '--top-module',top,'--Mdir',str(out/'obj'),'-o','test',*map(str,files)]
        save(out/'command.json',command)
        with (out/'build.log').open('x') as log:
            rc = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
        row = dict(name=name,build_exit=rc,passed=False,seeds=[])
        if rc: return row
        for seed in (1,7,101):
            with (out/f'run-{seed}.log').open('x') as log:
                rc = subprocess.run([out/'obj/test','+verilator+rand+reset+2',
                    '+verilator+seed+'+str(seed)],stdout=log,stderr=subprocess.STDOUT,timeout=20).returncode
            text = (out/f'run-{seed}.log').read_text()
            item = dict(seed=seed,native_exit=rc)
            if suite=='focused':
                match=re.search(r'AXI-READ-THROUGH-OK cases=(\d+) command_delay=(\d+) responses=(\d+)',text)
                if match:
                    item.update(dict(zip(('cases','command_delay','responses'),map(int,match.groups()))))
                item['passed']=rc==0 and match is not None and item['cases']==289
            else:
                item['passed']=rc==0 and 'AXI2AVALON-WRAP-GATE-OK' in text and 'FAIL' not in text
                item['latencies']=[list(map(int,m)) for m in re.findall(
                    r'WRAP-LATENCY mode=(\d+) half=(\d+) word=(\d+) first=(\d+) total=(\d+)',text)]
                item['passed'] &= len(item['latencies'])==32
            row['seeds'].append(item)
        row['passed']=all(x['passed'] for x in row['seeds'])
        row['binary_sha256']=sha(out/'obj/test')
        print(json.dumps(dict(name=name,passed=row['passed'])),flush=True)
        return row
    result=dict(passed=False,rows=[],gameplay_ipc=None,standard_suite=False)
    try:
        with ThreadPoolExecutor(max_workers=4) as pool: result['rows']=list(pool.map(run,tasks))
        assert all(row['passed'] for row in result['rows'])
        table={r['name']:r for r in result['rows']}
        for profile in ('plain','bpipe','write'):
            for suite in ('focused','wrap'):
                controls=[table[profile+'-'+m+'-'+suite]['seeds'] for m in ('control','off','on')]
                assert controls[0]==controls[1], 'disabled-profile drift'
                for before,after in zip(controls[0],controls[2]):
                    if suite=='focused':
                        assert before['responses']==after['responses']
                        assert before['command_delay']-after['command_delay']==49
                    else:
                        for a,b in zip(before['latencies'],after['latencies']):
                            assert a[:3]==b[:3]
                            if a[0]==0: assert a[3]-b[3]==a[4]-b[4]==1
        assert table['real-control']['seeds']==table['real-off']['seeds']
        for before,after in zip(table['real-control']['seeds'],table['real-on']['seeds']):
            for a,b in zip(before['latencies'],after['latencies']):
                assert a[:3]==b[:3] and b[3]<=a[3] and b[4]<=a[4]
        result['passed']=True
    except Exception as exc: result['error']=repr(exc)
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out/'closed.json',result)
    assert result['passed'],result.get('error')

if __name__=='__main__':main()
