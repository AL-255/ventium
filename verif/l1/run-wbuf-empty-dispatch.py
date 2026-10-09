#!/usr/bin/env python3
"""Bounded A/B: empty dispatch latency, retained slots, independent AXI channels."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from prepare_wbuf_empty_dispatch import transform

REPO = Path(__file__).resolve().parents[2]
CHECK = '''
  // Native clock assertion: registered AW/W must be visible immediately
  // after an empty queue accepts a store, even if the slave blocks it.
  assert property (@(posedge clk) disable iff (!rst_n)
      (dut.wr_enq && !dut.wr_active && dut.wq_count == 0) |=>
      (awvalid && wvalid)) else $fatal(1, "empty dispatch latency bubble");
'''

# Reuse only the public DUT wiring from tb_axi_wbuf, not its slave/oracle.
BYTES = '''
  int cyc=0, mode=0, awn=0, wn=0, bn=0, stores=0;
  logic [39:0] aq[2048];
  logic [31:0] dq[2048];
  logic [3:0] sq[2048];
  byte unsigned mem[1024], expected[1024];
  logic read_pending=0;
  logic [31:0] read_data=0;
  assign awready=rst_n && ((mode==0) || (cyc%5==1));
  assign wready=rst_n && ((mode==0) || (cyc%7==3));
  assign bvalid=rst_n && bn<awn && bn<wn && ((mode==0) || (cyc%11==4));
  assign bid=0; assign bresp=0;
  assign arready=rst_n && !read_pending;
  assign rvalid=read_pending; assign rdata=read_data;
  assign rid=0; assign rresp=0; assign rlast=1;
  always @(posedge clk) begin
    if(!rst_n) begin
      cyc<=0;awn<=0;wn<=0;bn<=0;stores<=0;read_pending<=0;read_data<=0;
      foreach(mem[i]) mem[i]=0;
    end else begin
      cyc<=cyc+1;
      if(cyc>100000 || bus_err) $fatal(1,"timeout/fabric error");
      if(dut.wq_count>2) $fatal(1,"architectural queue grew");
      if(m_req && m_we && m_ack) stores<=stores+1;
      if(awvalid && awready) begin
        if(awlen!=0 || awsize!=2 || awburst!=1 || awaddr>=1024)
          $fatal(1,"bad AXI write extent");
        aq[awn]=awaddr;awn<=awn+1;
      end
      if(wvalid && wready) begin
        if(!wlast) $fatal(1,"unexpected nonfinal single-store beat");
        dq[wn]=wdata;sq[wn]=wstrb;wn<=wn+1;
      end
      if(bvalid && bready) begin
        for(int lane=0;lane<4;lane++)
          if(sq[bn][lane]) mem[int'(aq[bn])+lane]=dq[bn][8*lane+:8];
        bn<=bn+1;
      end
      if(arvalid && arready) begin
        if(bn!=awn || bn!=wn || dut.wq_count!=0)
          $fatal(1,"read overtook posted store");
        if(arlen!=0 || arsize!=2) $fatal(1,"bad narrow read");
        for(int lane=0;lane<4;lane++) read_data[8*lane+:8]<=mem[int'(araddr)+lane];
        read_pending<=1;
      end else if(rvalid && rready) read_pending<=0;
    end
  end
  task automatic store(input int addr,input logic[3:0] mask,input logic[31:0] data);
    @(negedge clk);m_req=1;m_we=1;m_addr=32'(addr);m_wstrb=mask;m_wdata=data;
    do begin @(posedge clk);end while(!m_ack);
    for(int lane=0;lane<4;lane++) if(mask[lane]) expected[addr+lane]=data[8*lane+:8];
    @(negedge clk);m_req=0;m_addr=32'hdeadbeef;m_wdata=32'h01234567;m_wstrb=0;
  endtask
  task automatic read_check(input int addr);
    logic[31:0] want;
    for(int lane=0;lane<4;lane++) want[8*lane+:8]=expected[addr+lane];
    @(negedge clk);m_req=1;m_we=0;m_addr=32'(addr);m_wstrb=15;m_rd_narrow=1;
    do begin @(posedge clk);end while(!m_ack);
    if(m_rdata!==want) $fatal(1,"ordered read mismatch addr=%0d got=%h want=%h",addr,m_rdata,want);
    @(negedge clk);m_req=0;
  endtask
  initial begin
    if(!$value$plusargs("MODE=%d",mode)) mode=0;
    foreach(expected[i]) expected[i]=0;
    repeat(4) @(negedge clk);rst_n=1;
    for(int pass=0;pass<2;pass++) begin
      for(int off=0;off<4;off++) for(int mask=0;mask<16;mask++) begin
        store(64+off,4'(mask),32'h579ace31 ^ (32'(mask)*32'h9e3779b9) ^ 32'(pass*7919+off));
        if((mask%4)==0) read_check(64);
      end
      read_check(64);read_check(68);
    end
    while(!m_idle) @(negedge clk);
    foreach(mem[i]) if(mem[i]!==expected[i]) $fatal(1,"memory mismatch byte=%0d",i);
    if(stores!=128 || awn!=wn || bn!=awn) $fatal(1,"store accounting mismatch");
    $display("WBUF-BYTE-OK mode=%0d cycles=%0d stores=%0d beats=%0d",mode,cyc,stores,bn);
    $finish;
  end
endmodule
'''


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 2*1024**3
    fds = tuple(int(p.name) for p in Path('/proc/self/fd').iterdir()
                if p.name.isdigit() and p.exists() and p.resolve() == Path('/tmp/ventium-heavy-build.lock'))
    assert fds, 'launch through build_scope.sh'
    out.mkdir()
    files = [Path(__file__).resolve(), REPO/'verif/l1/prepare_wbuf_empty_dispatch.py',
             REPO/'rtl/mem/ven_axi_master.sv']
    files += [REPO/'verif/l1'/('tb_axi_'+name+'.sv') for name in
              ('wbuf', 'quad_reuse', 'bresp_contain', 'id_contain', 'orphan_b_contain')]
    pins = {str(p): sha(p) for p in files}
    (out/'master.sv').write_text(transform((REPO/'rtl/mem/ven_axi_master.sv').read_text()))
    wiring = (REPO/'verif/l1/tb_axi_wbuf.sv').read_text()
    for name in ('wbuf', 'quad_reuse', 'bresp_contain', 'id_contain', 'orphan_b_contain'):
        text = (REPO/'verif/l1'/('tb_axi_'+name+'.sv')).read_text()
        if name == 'wbuf':
            text = text.replace('endmodule', '`ifdef EMPTY_LATENCY_CHECK\n'+CHECK+'`endif\nendmodule')
        (out/(name+'.sv')).write_text(text)
    (out/'bytes.sv').write_text(wiring.split('  int errors = 0;')[0] + BYTES)
    pins.update({str(p): sha(p) for p in out.glob('*.sv')})
    save(out/'pins.json', pins)
    jobs = []
    for on in (False, True):
        defs = ['VEN_P54_WBUF_EMPTY_DISPATCH', 'EMPTY_LATENCY_CHECK'] if on else []
        for name, extras in (
            ('base', []), ('pair', ['VEN_P54_DUAL_STORE_PAIR']),
            ('pipe', ['VEN_P54_WBUF_PIPE_DISPATCH', 'VEN_P54_WBUF_PIPE_DISPATCH_TEST']),
            ('alias', ['VEN_P54_DUAL_STORE_PAIR','VEN_P54_PAIR_ALIAS_TEST']),
            ('error', ['VEN_P54_DUAL_STORE_PAIR','VEN_P54_PAIR_ERROR_TEST','VEN_AXI_RESP_FAULT_INJECT']),
            ('readb', ['VEN_AXI_READ_ON_FINAL_B','VEN_AXI_READ_ON_FINAL_B_TEST']),
            ('readberr', ['VEN_AXI_READ_ON_FINAL_B','VEN_AXI_READ_ON_FINAL_B_TEST','VEN_AXI_READ_ON_FINAL_B_ERROR_TEST','VEN_AXI_RESP_FAULT_INJECT']),
        ):
            jobs.append((f'{on}-{name}', 'wbuf', 'tb_axi_wbuf', defs+extras, 'AXIWBUF-', False))
        jobs.append((f'{on}-bytes','bytes','tb_axi_wbuf',defs,'WBUF-BYTE-OK',False))
        for slot in (False, True):
            for blocked in (False, True):
                for quad in (False, True):
                    extras = ['VEN_P54_DUAL_STORE_PAIR', 'VEN_P54_WBUF_PIPE_DISPATCH']
                    if slot: extras += ['VEN_AXI_QUAD_REUSE_SLOT1']
                    if blocked: extras += ['VEN_AXI_QUAD_REUSE_BACKPRESSURE']
                    if quad: extras += ['VEN_P54_WBUF_QUAD_COMBINE']
                    jobs.append((f'{on}-reuse-{slot}-{blocked}-{quad}', 'quad_reuse', 'tb_axi_quad_reuse',
                                 defs+extras, 'AXI-QUAD-REUSE-GATE-OK', False))
        for name in ('bresp_contain','id_contain','orphan_b_contain'):
            # Exactly the environmental-violation macro used by each existing
            # gate; do not suppress ownership assertions in healthy tests.
            fault_defs = ['VEN_AXI_RESP_FAULT_INJECT'] if name == 'bresp_contain' else ['VEN_AXI_FAULT_INJECT']
            if name == 'orphan_b_contain':
                fault_defs += ['VEN_AXI_B_ORPHAN_INJECT']
            jobs.append((f'{on}-{name}',name,'tb_axi_'+name,defs+fault_defs, '-OK',False))
    jobs.append(('negative-latency','wbuf','tb_axi_wbuf',['EMPTY_LATENCY_CHECK'], 'empty dispatch latency bubble',True))
    result = dict(passed=False, rows=[], gameplay_ipc=None, standard_suite=False)

    def build_run(job):
        name, source, top, defs, marker, negative = job
        dst = out/name
        dst.mkdir()
        command = ['/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert','-sv','-j','8',
            '-Wall','-Wno-fatal','-Wno-UNUSED', *['-Werror-'+k for k in
            ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            *['-D'+d for d in defs], '--top-module',top,'--Mdir',str(dst/'obj'),'-o','test',
            str(out/'master.sv'),str(out/(source+'.sv'))]
        save(dst/'command.json',command)
        with (dst/'build.log').open('x') as log:
            rc = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180,pass_fds=fds).returncode
        if rc: return dict(name=name,passed=False,build_exit=rc)
        rows=[]
        for seed in (1,7,101):
            for mode in ((0,1) if source=='bytes' else (0,)):
                logpath=dst/f'run-{seed}-{mode}.log'
                with logpath.open('x') as log:
                    rc=subprocess.run([dst/'obj/test',f'+MODE={mode}','+verilator+rand+reset+2',f'+verilator+seed+{seed}'],
                        stdout=log,stderr=subprocess.STDOUT,timeout=20).returncode
                text=logpath.read_text()
                rows.append(dict(seed=seed,mode=mode,native_exit=rc,negative=negative,
                                 passed=(rc!=0 if negative else rc==0) and marker in text))
        save(dst/'closed.json',rows)
        return dict(name=name,passed=all(r['passed'] for r in rows),runs=rows)
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            result['rows']=list(pool.map(build_run,jobs))
        assert all(r['passed'] for r in result['rows']), [r['name'] for r in result['rows'] if not r['passed']]
        result['passed']=True
    except Exception as exc:
        result['error']=repr(exc)
    finally:
        result['stable_inputs']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['stable_inputs']
        save(out/'closed.json',result)
    print(json.dumps(dict(passed=result['passed'],profiles=len(result['rows']),error=result.get('error'))))
    assert result['passed']


if __name__ == '__main__':
    main()
