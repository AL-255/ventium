#!/usr/bin/env python3
"""Run the existing ordered-traffic scoreboard on vendor functional netlists.

This is a bounded leaf test, not CPU timing, formal equivalence or guest PASS.
It waits for no jobs: the mapping run must already have closed successfully.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

REPO=Path(__file__).resolve().parents[1]
VENDOR=Path('/tools/Xilinx/2025.2/Vivado/data/verilog/src')
BIN=Path('/tools/Xilinx/2025.2/Vivado/bin')
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mapping',type=Path)
    ap.add_argument('--out-name',default='postsim')
    args=ap.parse_args()
    root=args.mapping.resolve(strict=True)
    assert root.parent==Path('/home/yukidama/external/tmp').resolve() and root.name.startswith('ventium-posted-physical.')
    closed=json.loads((root/'closed.json').read_text())
    assert closed['native_exit']==0 and closed['inputs_unchanged'] and closed['resource_stop'] is None
    assert subprocess.check_output(['systemctl','--user','show','ventium-vivado.scope','-p','ActiveState','--value'],text=True).strip() in ('inactive','failed')
    pins=json.loads((root/'inputs.json').read_text())
    assert all(digest(Path(p))==h for p,h in pins.items())
    assert re.fullmatch(r'postsim(?:-[a-z0-9]+)*',args.out_name),'invalid output leaf'
    post=root/args.out_name;post.mkdir()
    tb=REPO/'fpga/ven_ddram_axi_throughput_tb.sv'
    pins[str(tb)]=digest(tb)
    shutil.copyfile(tb,post/tb.name);tb=post/tb.name;pins[str(tb)]=digest(tb)
    # GSR is a vendor startup effect, not a DUT failure workaround. No DUT
    # register forcing or state injection; ordinary reset is simply held longer.
    pins[str(VENDOR/'glbl.v')]=digest(VENDOR/'glbl.v')
    pins[str(Path(__file__).resolve())]=digest(Path(__file__).resolve())
    results=[]
    def native(argv,label,cwd,limit=120):
        argv=list(map(str,argv))
        with (post/(label+'-command.json')).open('x') as out:json.dump(argv,out,indent=2)
        cmd=[str(REPO/'tools/build_scope.sh'),'--','timeout','--signal=TERM','--kill-after=10s',str(limit),*argv]
        env={k:v for k,v in os.environ.items() if not k.startswith(('VENTIUM_','VEN_','AXI_','TB_'))}
        env.update(TMPDIR=str(post),PYTHONDONTWRITEBYTECODE='1')
        with (post/(label+'.log')).open('xb') as log:
            p=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=limit+60)
        assert p.returncode==0,(label,p.returncode)
    for profile in ('serial','posted4','posted8','posted16'):
        for stage in ('rtl','synth','route'):
            name=profile+'-'+stage
            folder=post/name;folder.mkdir()
            net=(root/'inputs'/('serial.v' if profile=='serial' else 'posted.sv')) if stage=='rtl' else root/f'reports/{name}.v'
            pins[str(net)]=digest(net)
            if profile=='serial' and stage=='rtl':
                # The frozen legacy source declares m_wv after a continuous
                # use. Vivado synth/Verilator accept it; xelab rejects it even
                # in SV mode. Move ONLY its uninitialized declaration in a
                # private parser adapter. No logic, reset or netlist changes.
                text=net.read_text()
                declaration='    reg m_wv;\n'
                before='    reg [63:0] wd; reg [7:0] ws; reg wl;\n'
                assert text.count(declaration)==text.count(before)==1
                text=text.replace(declaration,'').replace(before,declaration+before)
                net=folder/'serial-declaration-order.sv';net.write_text(text)
                pins[str(net)]=digest(net)
            slots=4 if profile=='serial' else int(profile.removeprefix('posted'))
            wrapper=folder/'wrapper.sv'
            wrapper.write_text(f'module board_netlist_tb;\nven_ddram_axi_throughput_tb #(.RESET_CYCLES(30),.WRITE_SLOTS({slots})) traffic();\nendmodule\n')
            pins[str(wrapper)]=digest(wrapper)
            defines=[] if profile=='serial' else ['VEN_TEST_POSTED']
            if profile!='serial' and stage!='rtl':defines+=['VEN_TEST_NETLIST']
            native(['iverilog','-g2012','-s','board_netlist_tb','-s','glbl',
                    *['-D'+d for d in defines],'-y',VENDOR/'unisims','-I',VENDOR,
                    '-M',f'all={folder}/deps','-o',folder/'parse.vvp',tb,wrapper,net,VENDOR/'glbl.v'],name+'-parse',folder)
            libs=sorted({Path(line.strip()) for line in (folder/'deps').read_text().splitlines()
                         if Path(line.strip()).parent==VENDOR/'unisims'})
            assert libs or stage=='rtl'
            for p in libs:pins[str(p)]=digest(p)
            command=[BIN/'xelab','--mt','2','--snapshot','dut','--log','elaborate.log',
                     '--svlog',tb,'--svlog',wrapper,'--svlog' if stage=='rtl' else '--vlog',net,'--vlog',VENDOR/'glbl.v']
            for define in defines:command+=['--define',define]
            for lib in libs:command+=['--vlog',lib]
            command+=['board_netlist_tb','glbl']
            native(command,name+'-elaborate',folder)
            native([BIN/'xsim','dut','--runall','--onerror','quit','--onfinish','quit','--stats',
                    '--log','simulate.log','--clear_child_on_exit'],name+'-simulate',folder)
            text=(folder/'simulate.log').read_text()
            assert 'DDRAM-THROUGHPUT-OK b_latency=20 writes=64' in text,text[-3000:]
            assert not re.search(r'(?im)^\s*(fatal|error)(:|\s*\[)',text),text[-3000:]
            cycles=int(re.search(r'drained_cycles=(\d+)',text)[1])
            results.append(dict(profile=profile,stage=stage,cycles=cycles,netlist_sha256=digest(net)))
            print(json.dumps(results[-1]),flush=True)
        assert len({r['cycles'] for r in results if r['profile']==profile})==1,'RTL/netlist cycle disagreement'
    assert all(digest(Path(p))==h for p,h in pins.items())
    with (post/'closed.json').open('x') as out:
        json.dump(dict(passed=True,results=results,source_pins=pins,cpu_fmax_qualified=False,
                       gameplay_ipc=None,standard_suite=False),out,indent=2)
    print('POSTED-VENDOR-NETLIST-SCOREBOARD-OK',flush=True)
if __name__=='__main__':main()
