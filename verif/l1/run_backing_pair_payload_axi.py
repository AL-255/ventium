"""Compare two full L1s connected to independent real AXI masters and RAM BFMs."""
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

import prepare_backing_pair_payload as recipe
import run_parallel_tag_cache as miter
from test_backing_pair_payload import sha

REPO=Path(__file__).resolve().parents[2]
MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'
FIXTURE_SHA='83d4be64d0eac1c5dacdebca2d0ef8f814c000baa24cc0c2dd66485a63c8f2be'
MASTER_SHA='ed11478bcf7898e410b5d9bd4f1952d8d3291037f38987c3c01eb935b9b13e38'
AXI=dict(awid=4,awaddr=40,awlen=8,awsize=3,awburst=2,awlock=1,awcache=4,
         awprot=3,awqos=4,awvalid=1,awready=1,wdata=32,wstrb=4,wlast=1,wvalid=1,
         wready=1,bid=4,bresp=2,bvalid=1,bready=1,arid=4,araddr=40,arlen=8,
         arsize=3,arburst=2,arlock=1,arcache=4,arprot=3,arqos=4,arvalid=1,
         arready=1,rid=4,rdata=32,rresp=2,rlast=1,rvalid=1,rready=1)


def fixture(source):
    end='  ven_l1d dut(.*);'
    assert source.count(end)==1
    tb=source[:source.index(end)+len(end)]
    assert tb.count('m_pair_ready=1')==1
    tb=tb.replace('m_pair_ready=1','m_pair_ready')
    tb=tb.replace(end,'  logic c_read_ack;\n  wire c_payload_code=c_code;\n'+end)
    miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_ack=1,
        m_pair_req=1,m_pair_addr=32,m_pair_wdata=32,m_pair_wstrb=4,
        pair_req_ready=2,pair_req_split=2,pair_bank_conflict=1,
        pair_rsp_valid=2,pair_rsp_cancel=2,pair_rsp_owner=32,
        pair_rsp_paddr=64,pair_rsp_data=64,pair_now_valid=1,pair_now_data=32)
    tb=miter.miter_fixture(tb,False,True)
    for name in ('m_addr','m_wstrb'):
        before=f'if (dut.{name} !== shadow_{name})'
        assert tb.count(before)==1
        tb=tb.replace(before,f'if ((dut.m_req || (dut.st==dut.L1_IDLE && c_req && !dut.stream_path)) && dut.{name} !== shadow_{name})')
    extra='  logic [31:0] shadow_m_rdata;\n  logic shadow_m_ack,shadow_m_pair_ack,shadow_m_pair_ready;\n'
    wiring=', '.join(f'.{n}(shadow_{n})' for n in ('m_rdata','m_ack','m_pair_ack','m_pair_ready'))
    tb=tb.replace('  control_l1d control(',extra+'  control_l1d control('+wiring+', ')
    for prefix in ('','shadow_'):
        for name,width in AXI.items(): tb+=f'  logic [{width-1}:0] {prefix}{name};\n'
        tb+=f'  logic {prefix}bus_err,{prefix}m_idle;\n'
        master=['.core_clk(clk)','.axi_clk(clk)','.core_rst_n(rst_n)','.axi_rst_n(rst_n)',
                ".shutdown(1'b0)",f'.bus_err({prefix}bus_err)',f'.m_idle({prefix}m_idle)']
        master += [f'.{name}({prefix}{name})' for name in
                   (*recipe.FIELDS,'m_ack','m_rdata','m_pair_ack','m_pair_ready')]
        master += [f'.m_axi_{name}({prefix}{name})' for name in AXI]
        tb+=f'  ven_axi_master #(.ADDR_MASK(32\'h0000ffff),.LINE_REPLAY(0),.WATCHDOG(512)) {prefix}master (\n'
        tb+=',\n'.join(master)+',\n`ifdef VEN_DBG_CORE\n.dbg_rd_valid(),.dbg_rd_addr(),.dbg_rd_data(),\n`endif\n'
        # Leave a final ordinary port after conditional debug pins (no trailing comma).
        tb=tb.removesuffix(',\n`ifdef VEN_DBG_CORE\n.dbg_rd_valid(),.dbg_rd_addr(),.dbg_rd_data(),\n`endif\n')
        tb+='\n`ifdef VEN_DBG_CORE\n,.dbg_rd_valid(),.dbg_rd_addr(),.dbg_rd_data()\n`endif\n);\n'
        omitted={'awlock','awcache','awprot','awqos','arlock','arcache','arprot','arqos'}
        slave=['.clk(clk)','.rst_n(rst_n)']+[f'.{n}({prefix}{n})' for n in AXI if n not in omitted]
        tb+=f'  axi_slave_bfm #(.MEM_BYTES(65536),.RD_LAT(3),.WR_LAT(14),.BUBBLE(1)) {prefix}memory (\n'+',\n'.join(slave)+'\n);\n'
    tb+='  always @(posedge clk or negedge clk) begin\n    #1;\n'
    for n in (*AXI,'bus_err','m_idle','m_ack','m_rdata','m_pair_ack'):
        tb+=f'    if ({n} !== shadow_{n}) $fatal(1,"BACKING-AXI-MISMATCH {n}");\n'
    tb+='''    if (c_req && dut.st==dut.L1_IDLE && !dut.stream_path && m_pair_ready!==shadow_m_pair_ready)
      $fatal(1,"BACKING-AXI-MISMATCH observable credit");
'''
    for n in ('wq_count','wq_wp','wq_rp','wr_active','wr_active_slot','rst','wr_line','wr_cd'):
        tb+=f'    if (master.{n} !== shadow_master.{n}) $fatal(1,"BACKING-AXI-MISMATCH state {n}");\n'
    tb+='  end\n  `include "backing_pair_axi_leaf.svh"\nendmodule\n'
    return tb


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','fixture','leaf','out'):ap.add_argument('--'+n,type=Path,required=True)
    args=ap.parse_args(); parent=args.parent.resolve(strict=True)
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    load=lambda p:json.loads(p.read_text())
    before=load(parent/'build-started.json'); closed=load(parent/'build-closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==closed['binary_sha256']==MODEL
    leaf=args.leaf.resolve(strict=True); evidence=load(leaf/'closed.json')
    assert evidence['passed'] and evidence['pins_unchanged'] and len(evidence['rows'])==7
    assert all(sha(p)==h for p,h in evidence['pins'].items())
    source=parent/'candidate/rtl/mem/ven_l1d.sv'; old=source.read_text(); changed=recipe.transform(old)
    assert changed==(leaf/'ven_l1d.sv').read_text() and sha(leaf/'ven_l1d.sv')==evidence['derivative_sha256']
    master=parent/'candidate/rtl/mem/ven_axi_master.sv';assert sha(master)==MASTER_SHA
    base=args.fixture.resolve(strict=True);assert sha(base)==FIXTURE_SHA
    flags=next(s.split('=',1)[1].split() for s in before['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defines=[s for s in flags if s.startswith('+define+')]
    assert len(defines)==152 and all('+define+'+n in defines for n in
        ('VEN_P54_LOAD_STORE_PAIR','VEN_P54_WBUF_QUAD_COMBINE','VEN_P54_WBUF_ADMIT_DISPATCH'))
    root.mkdir(); here=Path(__file__).resolve().parent
    control=root/'control_l1d.sv';control.write_text(miter.control_source(old))
    bench=root/'tb_l1d_mem_chain.sv';bench.write_text(fixture(base.read_text()))
    modules=[parent/'candidate/rtl/mem'/n for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    pins=dict(evidence['pins'])
    for p in (Path(__file__).resolve(),Path(miter.__file__).resolve(),source,master,base,control,bench,
              here/'backing_pair_axi_leaf.svh',here/'axi_slave_bfm.sv',leaf/'closed.json',leaf/'ven_l1d.sv',
              parent/'build-started.json',parent/'build-closed.json',*modules):pins[str(p)]=sha(p)
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,defines=defines,invocation=os.environ['INVOCATION_ID']))
    result=dict(passed=False,rows=[],errors=[],full_cache=True,real_axi_master=True,
                whole_core=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    start=time.monotonic()
    try:
        for mutant in (False,True):
            folder=root/('wrong-u-address' if mutant else 'positive');folder.mkdir()
            sv=folder/'ven_l1d.sv'
            actual=recipe.block(changed)
            arm="m_req=1'b1; m_we=1'b1; m_addr=c_addr;"
            assert actual.count(arm)==1
            broken=actual.replace(arm,"m_req=1'b1; m_we=1'b1; m_addr=c_addr ^ 32'd4;")
            sv.write_text(changed.replace(actual,broken) if mutant else changed)
            command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                     '-j','32','-Wall','-Wno-UNUSED','-Wno-fatal',
                     *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                     '-I'+str(here),'--top-module','tb_l1d_mem_chain','--Mdir',str(folder/'obj'),'-o','test',
                     *defines,*map(str,modules),str(master),str(here/'axi_slave_bfm.sv'),str(control),str(sv),str(bench)]
            row=dict(mutant=mutant,command=command);result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                native=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit']=native.returncode;assert native.returncode==0
            with (folder/'run.log').open('x') as f:
                native=subprocess.run([folder/'obj/test'],stdout=f,stderr=subprocess.STDOUT,timeout=40)
            row['native_exit']=native.returncode;log=(folder/'run.log').read_text()
            if mutant:
                assert native.returncode in (1,-6,134) and re.search('BACKING-PAIR-PAYLOAD:|BACKING-AXI-MISMATCH|PARALLEL-CACHE-MISMATCH',log),log
            else:
                assert native.returncode==0 and 'BACKING-AXI-OK' in log,log
                assert not re.search('%Error|%Fatal|FATAL|FAIL|MISMATCH',log),log
                row['coverage']=re.findall(r'(?:BACKING-AXI-OK|PARALLEL-CACHE-MITER).*',log)
            row['artifacts']={str(p):sha(p) for p in (sv,folder/'obj/test',folder/'build.log',folder/'run.log')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('artifacts','command')}),flush=True)
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged'];save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
