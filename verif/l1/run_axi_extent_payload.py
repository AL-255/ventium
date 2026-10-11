#!/usr/bin/env python3
"""Compare actual source-extracted alias extents, including wrap and sparse masks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_axi_extent_payload import block, transform


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'),'--is-active'],pass_fds=(9,)).returncode == 0
    old = source.read_text(); new = transform(old)
    assert new.count("m_addr[31:2] + 30'd1") == 1
    mutant = new.replace("m_addr[31:2] + 30'd1", "m_addr[31:2] + 30'd0")
    out.mkdir()
    pins = {str(p):sha(p) for p in (source,Path(__file__),Path(__file__).with_name('prepare_axi_extent_payload.py'),
        repo/'tools/build_scope.sh',Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve())}
    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    wrapper = '''(input [5:0] ctrl, input [31:0] a,b,mask, input [7:0] strb,
                 output wire [83:0] result);
  wire m_req=ctrl[0], m_we=ctrl[1], m_rd_narrow=ctrl[2], m_pair_req=ctrl[5];
  wire [1:0] m_rd_size=ctrl[4:3];
  wire [31:0] m_addr=a, m_pair_addr=b, ADDR_MASK=mask;
  wire [3:0] m_wstrb=strb[3:0], m_pair_wstrb=strb[7:4];
  wire alias_bad;
  assign result={alias_ssh,alias_two,alias_last,alias_bad,pair_alias_ssh,pair_alias_last,pair_alias_bad,1'b0};
'''
    tb = out/'tb.sv'
    with tb.open('x') as f:
        for name,text in (('old_extent',old),('new_extent',new),('bad_extent',mutant)):
            f.write('module '+name+wrapper+block(text)+'endmodule\n')
        f.write('''module tb;
  reg [5:0] ctrl; reg [31:0] a,b,mask; reg [7:0] strb;
  wire [83:0] old_result,new_result,bad_result;
  old_extent ref_dut(ctrl,a,b,mask,strb,old_result);
  new_extent candidate(ctrl,a,b,mask,strb,new_result);
  bad_extent mutant(ctrl,a,b,mask,strb,bad_result);
  integer samples=0,active=0,rejected=0,wraps=0,mutant_mode;
  initial begin
    mutant_mode=$test$plusargs("mutant");
    for(integer c=0;c<64;c++) for(integer s=0;s<256;s++) for(integer k=0;k<64;k++) begin
      ctrl=6'(c); strb=8'(s);
      // Every bit boundary, 0/32-bit wrap, ROM exemption and sparse masks.
      a=(32'd1<<(k%32))-32'(s%8);
      if(k>=32) a=a^32'hfffe0000;
      b=~a; mask=k[5] ? (32'h55555555^(32'd1<<(k%32))) : ((32'd1<<(k%32))-1);
      #1;
      if(old_result !== (mutant_mode ? bad_result : new_result))
        $fatal(1,"AXI_EXTENT_MISMATCH c=%0d s=%0d k=%0d a=%h b=%h mask=%h",c,s,k,a,b,mask);
      samples++; active+=ctrl[0]; rejected+=ref_dut.alias_bad;
      wraps+=(ref_dut.alias_last<a);
    end
    if(samples!=1048576 || active==0 || rejected==0 || wraps==0) $fatal(1,"AXI_EXTENT_VACUOUS");
    $display("AXI-EXTENT-PAYLOAD-OK samples=%0d active=%0d rejected=%0d wraps=%0d",samples,active,rejected,wraps);
    $finish;
  end
endmodule
''')
    pins[str(tb)] = sha(tb)
    runs, error, start = [], None, time.monotonic()
    try:
        binary = out/'leaf.vvp'
        commands = [('build',['/usr/bin/iverilog','-g2012','-DVEN_P54_DUAL_STORE_PAIR','-s','tb','-o',str(binary),str(tb)],0),
            ('positive',['/usr/bin/vvp',str(binary)],0),('negative',['/usr/bin/vvp',str(binary),'+mutant'],1)]
        for label, command, expected in commands:
            save(label+'.command.json',command)
            with (out/(label+'.log')).open('x') as f:
                p = subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=60)
            runs.append(dict(label=label,native_exit=p.returncode,log_sha256=sha(out/(label+'.log'))))
            assert p.returncode == expected, runs[-1]
        assert 'AXI-EXTENT-PAYLOAD-OK samples=1048576' in (out/'positive.log').read_text()
        assert 'AXI_EXTENT_MISMATCH' in (out/'negative.log').read_text()
        pins[str(binary)] = sha(binary)
    except BaseException as exc:
        import traceback
        error = dict(error=repr(exc),traceback=traceback.format_exc())
    stable = all(sha(p)==h for p,h in pins.items())
    result = dict(passed=error is None and stable,pins=pins,pins_unchanged=stable,runs=runs,error=error,
        seconds=time.monotonic()-start,full_master=False,full_core=False,timing_mhz=None,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
