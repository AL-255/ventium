"""Unfiltered actual-L1 A/B miter for the backing payload mux refactor.

Use the original public-traffic fixture, including next-read conflicts and
idle V admission. No input contract filter or invalid-payload output mask.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_backing_payload_mux as recipe
import run_current_u_pair as inherited

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
DATA=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
sha=inherited.sha


def fixture(ports):
    tb=inherited.fixture(ports,False)
    tb=tb.replace("ven_l1d #(.PAIR_CURRENT_U_ONLY(1'b0))",'ven_l1d')
    tb=re.sub(r'  wire \[1:0\] contract_pair_valid =\n[^;]+;\n','',tb)
    tb=re.sub(r"if\(\([^\n]*?\) && (\w+)!==ref_(\w+)\)",r'if(\1!==ref_\2)',tb)
    tb=re.sub(r'if\(pair_rsp_valid\[([01])\] && ', 'if(',tb)
    assert 'contract_pair_valid' not in tb and 'PAIR_CURRENT_U_ONLY' not in tb
    assert 'if(m_addr!==ref_m_addr)' in tb and 'if(m_wstrb!==ref_m_wstrb)' in tb
    # The inherited traffic drops c_we together with c_req. Explicitly cover
    # idle U-write payload as well: full LOAD_STORE mode otherwise selects V,
    # hiding the late-U-address negative control even with unfiltered outputs.
    assert tb.count('    $finish;')==1
    tb=tb.replace('    $finish;', '''    @(negedge clk);
    if(dut.st!=dut.L1_IDLE || reference.st!=reference.L1_IDLE)
      $fatal(1,"BACKING-MUX-IDLE-COVERAGE not idle");
    c_req=0;c_we=1;c_addr=32'h13579bdf;c_wstrb=4'hf;
    c_pair_req=0;c_next_req=0;
    repeat(2) @(posedge clk);
    @(negedge clk);
    if(m_req || c_ack) $fatal(1,"BACKING-MUX-IDLE-COVERAGE side effect");
    c_we=0;
    repeat(2) @(posedge clk);
    $display("BACKING-MUX-IDLE-OK");
    $finish;''')
    return tb


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',required=True,type=Path)
    root=ap.parse_args().out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(32))
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']==inherited.original.VL
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    parent=DATA/'prefix-payload-core-r1'; proof=DATA/'backing-payload-mux-leaf-r1'
    prior=json.loads((parent/'build-started.json').read_text())
    checked=json.loads((proof/'closed.json').read_text())
    assert checked['passed'] and checked['pins_unchanged'] and checked['unfiltered_all_outputs']
    assert len(checked['rows'])==7 and sum(r['native_exit']==0 for r in checked['rows'])==3
    source_path=parent/'candidate/rtl/mem/ven_l1d.sv'; source=source_path.read_text()
    candidate=recipe.transform(source)
    assert candidate==(proof/'ven_l1d.sv').read_text()
    definitions=prior['definitions']; assert len(set(definitions))==len(definitions)==152
    assert not {'SYNTHESIS','VEN_L1D_COMB_ACK','VEN_P54_STORE_LOAD_PAIR','VEN_P54_DUAL_LOAD_PRIME'} & set(definitions)
    modules=[source_path.with_name(n) for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    inputs=[source_path,parent/'build-started.json',proof/'closed.json',proof/'ven_l1d.sv',
        Path(__file__),Path(inherited.__file__),Path(inherited.recipe.__file__),
        Path(inherited.original.__file__),HERE/'prepare_l1_legacy_capture_cut.py',
        HERE/'tb_l1d_mem_chain.sv',HERE/'l1_legacy_capture_cut_leaf.svh',
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',*modules]
    assert all(sha(p)==prior['pins'][str(p)] for p in [source_path,*modules])
    pins=dict(checked['pins'])
    for row in checked['rows']: pins.update(row['files'])
    pins.update({str(p.resolve()):sha(p) for p in inputs})
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir(); shutil.copyfile(Path(__file__),root/'driver_at_run.py')
    pins[str(root/'driver_at_run.py')]=sha(root/'driver_at_run.py')
    rows=[]; natives=[]; errors=[]; begin=time.monotonic()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    def run(label,command,seconds,cpu=None):
        command=list(map(str,command)); logpath=root/(label+'.log')
        with logpath.open('x') as log:
            child=subprocess.Popen(['timeout','--kill-after=5s',str(seconds)+'s',*command],
                stdout=log,stderr=subprocess.STDOUT,pass_fds=(9,),
                preexec_fn=(lambda:os.sched_setaffinity(0,{cpu})) if cpu is not None else None)
            affinity=sorted(os.sched_getaffinity(child.pid))
            assert affinity==([cpu] if cpu is not None else list(range(32)))
            code=child.wait(timeout=seconds+15)
        natives.append(dict(label=label,command=command,native_exit=code,
            affinity=affinity,actual_wait=True,reaped=True,log=str(logpath),sha256=sha(logpath)))
        return code,logpath.read_text()
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID']))
    try:
        for label,mutant in (('positive',False),('late-address-negative',True)):
            folder=root/label;folder.mkdir()
            new=candidate
            if mutant:
                assert new.count('    m_addr = c_addr;')==1
                new=new.replace('    m_addr = c_addr;',"    m_addr = c_req ? c_addr : 32'd0;",1)
            sv=folder/'ven_l1d.sv';sv.write_text(new)
            control=folder/'parent_l1d.sv'
            control.write_text(source.replace('module ven_l1d #(','module parent_l1d #(')
                              .replace('endmodule : ven_l1d','endmodule : parent_l1d'))
            rc,pp=run(label+'-preprocess',[inherited.original.VL,'-E',
                *['+define+'+d for d in definitions],sv],20)
            assert rc==0
            bench=folder/'tb_l1d_mem_chain.sv';bench.write_text(fixture(inherited.original.ports(pp)))
            for path in (sv,control,bench):pins[str(path)]=sha(path)
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-Wall',
                '-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in definitions],'--top-module','tb_l1d_mem_chain',
                '--Mdir',folder/'obj','-j','32',*modules,control,sv,bench]
            rc,log=run(label+'-build',command,180);assert rc==0,log[-3500:]
            model=folder/'obj/Vtb_l1d_mem_chain'
            rc,log=run(label+'-run',['taskset','-c','12',model],30,cpu=12)
            if mutant:
                assert rc in (1,-6,134) and ('BACKING-PAYLOAD-MUX:' in log or 'CUT_EQUIV m_addr' in log),log
            else:
                assert rc==0 and 'CURRENT-U-MITER-OK' in log and 'L1D-MEM-CHAIN-OK accepted=150' in log,log
                assert 'checks=538 fresh=448 same_bank=64 held=1536' in log,log
                assert 'BACKING-MUX-IDLE-OK' in log,log
            rows.append(dict(label=label,native_exit=rc,binary_sha256=sha(model),
                coverage=re.findall(r'^(?:L1.*OK|CURRENT-U-MITER-OK).*$',log,re.M)))
    except Exception as exc:
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=not errors and stable and len(rows)==2,rows=rows,errors=errors,
        pins=pins,pins_unchanged=stable,native=natives,seconds=time.monotonic()-begin,
        contract_filter=None,output_filter=None,whole_core=False,hardware_acceptance=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','native')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
