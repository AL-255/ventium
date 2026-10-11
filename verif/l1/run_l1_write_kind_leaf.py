#!/usr/bin/env python3
"""Bounded comparison of the actual old/new L1 backing-drive blocks.

This proves the offered interface, not whole-cache state, AXI behavior, timing
or system acceptance. Preserve native evidence and run under the build guard.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_l1_write_kind_payload import backing_block, transform


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out, source = args.out.resolve(), args.source.resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'],
                          pass_fds=(9,)).returncode == 0
    old = source.read_text()
    new = transform(old)
    out.mkdir()
    pins = {str(p): sha(p) for p in (source, Path(__file__),
        repo/'verif/l1/prepare_l1_write_kind_payload.py',
        repo/'tools/build_scope.sh', Path('/usr/bin/iverilog').resolve(),
        Path('/usr/bin/vvp').resolve())}

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), full_cache=False, timing_mhz=None))
    wrapper = '''(input [8:0] ctrl, input [31:0] a,b,d, input [3:0] strobes,
                 input [2:0] beat, output logic req, output logic we,
                 output wire [140:0] payload);
  localparam L1_IDLE=0, L1_FILL=1;
  wire [1:0] st=ctrl[1:0];
  wire c_req=ctrl[2], c_we=ctrl[3], stream_path=ctrl[4];
  wire c_pair_req=ctrl[5], c_pair_ready=ctrl[6];
  wire bypass_q=ctrl[7], byp_hi_beat=ctrl[8];
  wire [31:0] c_addr=a, c_pair_addr=b, fbase=b;
  wire [31:0] c_wdata=d, c_pair_wdata=~d;
  wire [3:0] c_wstrb=strobes, c_pair_wstrb=~strobes;
  wire [2:0] fw=beat, fill_word=fbase[4:2]+fw;
  wire [2:0] byp_off_q[4];
  wire [1:0] byp_siz_q[4];
  for(genvar i=0;i<4;i++) begin
    assign byp_off_q[i]=beat+3'(i);
    assign byp_siz_q[i]=2'(i);
  end
  logic m_req,m_we,m_rd_narrow,m_pair_req;
  logic [31:0] m_addr,m_wdata,m_pair_addr,m_pair_wdata;
  logic [3:0] m_wstrb,m_pair_wstrb;
  logic [1:0] m_rd_size;
  always_comb begin req=m_req; we=m_we; end
  assign payload={m_req,m_addr,m_wdata,m_wstrb,m_rd_narrow,m_rd_size,
                  m_pair_req,m_pair_addr,m_pair_wdata,m_pair_wstrb};
'''
    tb = out/'tb.sv'
    with tb.open('x') as f:
        for name, text in (('old_drive', old), ('new_drive', new)):
            f.write('module '+name+wrapper+backing_block(text)+'endmodule\n')
        f.write('''module tb;
  reg [8:0] ctrl; reg [31:0] a,b,d; reg [3:0] strobes; reg [2:0] beat;
  wire old_req,new_req,old_we,new_we;
  wire [140:0] old_payload,new_payload;
  old_drive old(ctrl,a,b,d,strobes,beat,old_req,old_we,old_payload);
  new_drive dut(ctrl,a,b,d,strobes,beat,new_req,new_we,new_payload);
  integer samples=0,active=0,inactive_direction_changes=0,mutant;
  initial begin
    mutant=$test$plusargs("mutant_clear_write");
    for(integer c=0;c<512;c++) begin
      for(integer k=0;k<32;k++) begin
        ctrl=9'(c); a=32'h0fffffff^(32'd1<<k); b=~a; d=32'h12345678^a;
        strobes=4'(k); beat=3'(k); #1;
        if(old_payload!==new_payload || old_req!==new_req)
          $fatal(1,"WRITE_KIND_CHANGED_REQUEST_OR_PAYLOAD c=%0d k=%0d",c,k);
        if(old_req) begin
          active++;
          if(old_we!==(mutant?1'b0:new_we))
            $fatal(1,"WRITE_KIND_CHANGED_ACTIVE_DIRECTION c=%0d k=%0d",c,k);
        end else if(old_we!==new_we) inactive_direction_changes++;
        samples++;
      end
    end
    if(samples!=16384 || active==0 || inactive_direction_changes==0)
      $fatal(1,"WRITE_KIND_VACUOUS");
    $display("WRITE-KIND-LEAF-OK samples=%0d active=%0d inactive_direction_changes=%0d",
             samples,active,inactive_direction_changes);
    $finish;
  end
endmodule
''')
    pins[str(tb)] = sha(tb)
    runs, began, error = [], time.monotonic(), None
    try:
        binary = out/'leaf.vvp'
        commands = [
            ('build', ['/usr/bin/iverilog', '-g2012', '-s', 'tb',
                       '-DVEN_P54_DUAL_STORE_PAIR', '-DVEN_P54_LOAD_STORE_PAIR',
                       '-o', str(binary), str(tb)], 0),
            ('positive', ['/usr/bin/vvp', str(binary)], 0),
            ('negative', ['/usr/bin/vvp', str(binary), '+mutant_clear_write'], 1)]
        for label, command, expected in commands:
            save(label+'.command.json', command)
            log = out/(label+'.log')
            with log.open('x') as f:
                p = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=60)
            runs.append(dict(label=label, native_exit=p.returncode, log_sha256=sha(log)))
            assert p.returncode == expected, runs[-1]
            if label == 'positive':
                assert 'WRITE-KIND-LEAF-OK samples=16384 ' in log.read_text()
            if label == 'negative':
                assert 'WRITE_KIND_CHANGED_ACTIVE_DIRECTION' in log.read_text()
        pins[str(binary)] = sha(binary)
    except BaseException as exc:
        import traceback
        error = dict(error=repr(exc), traceback=traceback.format_exc())
    stable = all(sha(p)==h for p,h in pins.items())
    result = dict(passed=error is None and stable, error=error, runs=runs,
        pins=pins, pins_unchanged=stable, seconds=time.monotonic()-began,
        full_cache=False, axi_acceptance=False, timing_mhz=None,
        standard_suite=False, gameplay_ipc=None, hardware_acceptance=False)
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
