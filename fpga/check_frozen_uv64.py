"""Check a frozen image's actual counter and scan mux, not processor execution.

Compile verbatim RTL fragments under the exported hardware definitions. Test
reset, all retirement pulse combinations, scan selection and seeded wrap seams.
Seeds affect only this isolated counter testbench. No FPGA, guest or RTL source
is modified; this cannot qualify gameplay IPC, CDC or a complete processor.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

TOP = 'ventium/rtl/ventium_top.sv'
SHIM = 'ventium/ao486-sim/ven/ven_ao486_shim.sv'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def exactly_one(pattern, text):
    found = re.findall(pattern, text, re.S)
    assert len(found) == 1, (pattern, len(found))
    return found[0]


def fragments(top, shim):
    counter = exactly_one(
        r"(  always_ff @\(posedge clk\) begin\n    if \(!rst_n\) begin\n"
        r"      retire_n <= 64'd0;.*?\n  end\n)\n`ifdef VEN_KV260_SOC", top)
    assignment = exactly_one(r'(  assign retire_count = retire_n;)', top)
    mux = exactly_one(r'    always_comb begin\n        case \(dbg_cmp\[106:100\]\).*?    end\n', shim)
    assert shim.count('.retire_count(v_retire_count)') == 1
    assert shim.count('assign dbg_bus = { d_scan_data,') == 1
    return counter, assignment, mux


def testbench(top, shim, mutation=None):
    counter, assignment, mux = fragments(top, shim)
    if mutation == 'u-only':
        old = "retire_n + (core_retire2_valid ? 64'd2 : 64'd1)"
        assert counter.count(old) == 1
        counter = counter.replace(old, "retire_n + 64'd1")
    elif mutation == 'swapped-words':
        assert mux.count('v_retire_count[31:0]') == mux.count('v_retire_count[63:32]') == 1
        mux = mux.replace('v_retire_count[31:0]', 'SWAP_WORD')
        mux = mux.replace('v_retire_count[63:32]', 'v_retire_count[31:0]')
        mux = mux.replace('SWAP_WORD', 'v_retire_count[63:32]')
    else:
        assert mutation is None
    return '''module uv64_tb;
  logic clk=0, rst_n=0, core_retire_valid=0, core_retire2_valid=0;
  logic [63:0] retire_n, retire_count;
  wire [63:0] v_retire_count = retire_count;
  logic [127:0] dbg_cmp=0;
  logic [31:0] d_arch_data=32'h90abcdef, d_scan_data;
  logic [63:0] expected=0;
  logic [31:0] scan_expected;
  integer clocks=0, scans=0;
''' + counter + assignment + '\n' + mux + r'''
  task automatic check_scan;
    for (integer sel=0;sel<128;sel=sel+1) begin
      dbg_cmp[106:100]=7'(sel); #1;
      case(sel)
        76: scan_expected=expected[31:0];
        77: scan_expected=expected[63:32];
        78: scan_expected=32'h55563634;
        79: scan_expected=32'h50440000 | {29'd0,dbg_cmp[109:107]};
        default: scan_expected=d_arch_data;
      endcase
      if (d_scan_data !== scan_expected)
        $fatal(1,"UV64-SCAN selector=%0d actual=%h expected=%h",sel,d_scan_data,scan_expected);
      if (retire_count !== expected) $fatal(1,"UV64-SELECT-CHANGED-COUNT");
      scans=scans+1;
    end
  endtask
  task automatic tick(input logic reset, input logic u, input logic v);
    rst_n=!reset; core_retire_valid=u; core_retire2_valid=v;
    if (reset) expected=0;
    else if (u) expected=expected + (v ? 64'd2 : 64'd1);
    #1; clk=1; #1; clk=0; #1;
    if (retire_count !== expected)
      $fatal(1,"UV64-COUNT u=%0d v=%0d actual=%h expected=%h",u,v,retire_count,expected);
    clocks=clocks+1; check_scan();
  endtask
  initial begin
    tick(1,0,0);
    for (integer i=0;i<256;i=i+1) begin
      dbg_cmp[109:107]=3'(i);
      d_arch_data=32'h87654321 ^ 32'(i);
      tick((i%37)==0,1'(i),1'(i>>1));
    end
    // White-box seam initialization is local to this counter leaf only.
    // It is not a processor save-state or hardware acceptance technique.
    for (integer seam=0;seam<2;seam=seam+1) begin
      expected=seam ? 64'hfffffffffffffffc : 64'h00000000fffffffc;
      retire_n=expected; #1; check_scan();
      tick(0,1,0); tick(0,1,1); tick(0,1,1);
      tick(0,0,1); tick(0,1,0); tick(1,1,1);
    end
    $display("FROZEN-UV64-OK clocks=%0d scans=%0d",clocks,scans);
    $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert os.sched_getaffinity(0) == {12} and os.environ.get('INVOCATION_ID')
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['qualification'] == 'UNQUALIFIED'
    definitions = (source/'defines.txt').read_text().splitlines()
    assert definitions == manifest['hardware_defines']
    assert {'SYNTHESIS','VTM_NO_DPI','VEN_KV260_SOC','VEN_DBG_CORE','VEN_DDR_POSTED'} <= set(definitions)
    pins = {}
    for row in manifest['files']:
        path = source/row['frozen']
        assert path.resolve(strict=True).is_relative_to(source) and not path.is_symlink()
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
        pins[str(path)] = row['sha256']
    for path in (source/'input-manifest.json',source/'defines.txt',Path(__file__).resolve()):
        pins[str(path)] = sha(path)
    top, shim = (source/TOP).read_text(), (source/SHIM).read_text()
    out.mkdir()
    def save(name, data):
        with (out/name).open('x') as stream:
            json.dump(data,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),source_manifest_sha256=sha(source/'input-manifest.json'),
        hardware_defines=definitions,scope='counter/mux fragments only; no processor or CDC'))
    rows, errors = [], []
    begin = time.monotonic()
    try:
        for mutation in (None,'u-only','swapped-words'):
            name = mutation or 'positive'
            tb, binary = out/(name+'.sv'), out/(name+'.vvp')
            with tb.open('x') as stream: stream.write(testbench(top,shim,mutation))
            command = ['iverilog','-g2012','-s','uv64_tb','-o',str(binary),
                       *['-D'+d for d in definitions],str(tb)]
            built = subprocess.run(command,capture_output=True,text=True,timeout=30)
            (out/(name+'-build.log')).write_text(built.stdout+built.stderr)
            assert built.returncode == 0, built.stderr
            ran = subprocess.run(['vvp',str(binary)],capture_output=True,text=True,timeout=30)
            log = ran.stdout+ran.stderr
            (out/(name+'-run.log')).write_text(log)
            if mutation is None:
                assert ran.returncode == 0 and 'FROZEN-UV64-OK clocks=269 scans=34688' in log, log
            else:
                expected_failure = 'UV64-COUNT' if mutation == 'u-only' else 'UV64-SCAN'
                assert ran.returncode == 1 and expected_failure in log and 'FROZEN-UV64-OK' not in log,log
            rows.append(dict(name=name,command=command,compile_exit=built.returncode,
                native_exit=ran.returncode,expected_failure=mutation is not None,
                source_sha256=sha(tb),binary_sha256=sha(binary),log_sha256=sha(out/(name+'-run.log'))))
    except Exception as error:
        errors.append(repr(error))
    stable = all(sha(path) == digest for path,digest in pins.items())
    result = dict(passed=not errors and len(rows)==3 and stable,errors=errors,rows=rows,
        pins_unchanged=stable,seconds=time.monotonic()-begin,processor_test=False,
        hardware_acceptance=False,cdc_qualified=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
