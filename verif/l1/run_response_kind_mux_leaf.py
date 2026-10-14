"""Native source-extracted mux miter, plus an unconstrained all-bit contract.

This is not a cache-sequential, processor, synthesis or FPGA qualification.
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

import prepare_response_kind_mux as recipe

FLAGS = ('VEN_L1D_PAYLOAD_CODE_HINT', 'VEN_L1D_RESPONSE_PAYLOAD_SELECT',
         'VEN_L1D_CODE_WORD_REUSE', 'VEN_L1D_CODE_PAYLOAD_SELECT', 'VEN_L1D_CODE_BUFFER',
         'VEN_L1D_HIT_STREAM')
INPUTS = ('c_payload_code c_payload_cacheable golden stream_path rd_armed rd_code_q '
          'early_armed early_code_q shadow_valid_q c_addr rd_addr_q early_addr_q '
          'fbase early_rdata_q shadow_line_addr_q c_wstrb early_wstrb_q st '
          'rd_window_q shadow_line_q code_line_q bp_line_x').split()
PORTS = '''input wire c_payload_code,c_payload_cacheable,golden,stream_path,
rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q,
input wire [31:0] c_addr,rd_addr_q,early_addr_q,fbase,early_rdata_q,
input wire [31:5] shadow_line_addr_q,
input wire [3:0] c_wstrb,early_wstrb_q,
input wire [1:0] st,
input wire [511:0] rd_window_q,
input wire [255:0] shadow_line_q,code_line_q,
input wire [287:0] bp_line_x,
output reg [31:0] c_rdata'''


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def leaf(source, name, candidate):
    names = ['code_payload_access', 'rd_payload_match', 'early_payload_match',
             'code_payload_select', 'shadow_payload_select']
    if candidate:
        names += ['response_kind_rd_owner', 'response_kind_early_owner',
                  'response_kind_shadow_owner', 'response_kind_primary',
                  'response_kind_code', 'response_kind_data']
    statements = []
    for signal in names:
        matches = list(re.finditer(r'\bwire\s+(?:\[[^\]]+\]\s+)?'+signal+r'\s*=', source))
        assert len(matches) == 1, signal
        start = matches[0].start()
        statements.append(source[start:source.index(';', start)+1])
    start = source.index('    c_rdata =', source.index('// an armed but unmatched fill'))
    end = source.index(recipe.MUX_ANCHOR, start)
    stream = "      c_rdata = rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];"
    assert source.count(stream) == 1, 'stream override absent/ambiguous in extracted profile'
    return ('module '+name+'('+PORTS+');\nlocalparam [1:0] L1_BYP=3;\n'+
            '\n'.join(statements)+'\nalways @* begin\n'+source[start:end]+
            '\nif (stream_path) begin\n'+stream+'\nend\nend\nendmodule\n')


TB = r'''
module tb;
reg c_payload_code,c_payload_cacheable,golden,stream_path,rd_armed,rd_code_q;
reg early_armed,early_code_q,shadow_valid_q;
reg [31:0] c_addr,rd_addr_q,early_addr_q,fbase,early_rdata_q;
reg [31:5] shadow_line_addr_q;
reg [3:0] c_wstrb,early_wstrb_q;
reg [1:0] st;
reg [511:0] rd_window_q;
reg [255:0] shadow_line_q,code_line_q;
reg [287:0] bp_line_x;
wire [31:0] data[0:1];
INSTANCES
integer selected[0:5];
integer partial_code=0;
initial begin
  for (integer k=0;k<6;k=k+1) selected[k]=0;
  for (integer i=0;i<262144;i=i+1) begin
    {st,c_payload_code,c_payload_cacheable,golden,stream_path,
     rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q}=i[14:4];
    c_addr=$random; c_wstrb=$random; fbase=$random;
    if (i[15]) begin c_addr[1:0]=0; c_wstrb=i[16] ? 4'hf : 4'h0; end
    rd_addr_q=i[0] ? c_addr : c_addr^32'h40;
    early_addr_q=i[1] ? c_addr : c_addr^32'h20;
    early_wstrb_q=i[2] ? c_wstrb : c_wstrb^4'hf;
    shadow_line_addr_q=i[3] ? c_addr[31:5] : c_addr[31:5]^27'h1;
    early_rdata_q=$random;
    for (integer k=0;k<16;k=k+1) rd_window_q[k*32+:32]=$random;
    for (integer k=0;k<8;k=k+1) begin
      shadow_line_q[k*32+:32]=$random; code_line_q[k*32+:32]=$random;
    end
    for (integer k=0;k<9;k=k+1) bp_line_x[k*32+:32]=$random;
    #1;
    // No ACK, code/data coherence or reachable-state assumptions: arbitrary
    // saved windows may disagree and idle payloads must still be equal.
    if (data[0] !== data[1]) $fatal(1,"RESPONSE-KIND-DATA i=%0d",i);
    if (stream_path) selected[0]=selected[0]+1;
    else if (st==3) selected[1]=selected[1]+1;
    else if (u0.early_payload_match) selected[2]=selected[2]+1;
    else if (u0.code_payload_select) selected[3]=selected[3]+1;
    else if (u0.shadow_payload_select) selected[4]=selected[4]+1;
    else selected[5]=selected[5]+1;
    if (c_payload_code && !u0.code_payload_access) partial_code=partial_code+1;
  end
  for (integer k=0;k<6;k=k+1)
    if (selected[k]==0) $fatal(1,"RESPONSE-KIND-COVERAGE k=%0d",k);
  if (partial_code==0) $fatal(1,"RESPONSE-KIND-PARTIAL");
  $display("RESPONSE-KIND-OK vectors=262144 stream=%0d bypass=%0d early=%0d code=%0d shadow=%0d primary=%0d partial_code=%0d",
    selected[0],selected[1],selected[2],selected[3],selected[4],selected[5],partial_code);
  $finish;
end
endmodule
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0) == {12}
    assert shutil.disk_usage(scratch).free > 4*1024**3
    source = (parent/recipe.FILE).read_text()
    candidate = recipe.transform(source)
    root.mkdir()
    pins = {str(p.resolve()): sha(p) for p in (parent/recipe.FILE, Path(__file__),
            Path(recipe.__file__), Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'), Path('/usr/bin/z3'))}
    rows, errors = [], []
    started = time.monotonic()

    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def run(name, argv, expected_exit=0, marker=None, timeout=60):
        with (root/(name+'.log')).open('x') as log:
            process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
            affinity = sorted(os.sched_getaffinity(process.pid))
            try:
                code = process.wait(timeout=timeout)
            except BaseException:
                process.kill(); process.wait()
                raise
        text = (root/(name+'.log')).read_text()
        row = dict(name=name, command=[str(a) for a in argv], native_exit=code,
                   child_affinity=affinity, child_reaped=True, log_sha256=sha(root/(name+'.log')))
        rows.append(row)
        assert affinity == [12] and code == expected_exit and (marker is None or marker in text), (name, text)
        return text

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
                             definitions=FLAGS, source_scope='combinational response only'))
    try:
        leaves = []
        for name, text in (('control', source), ('candidate', candidate)):
            path, pp = root/(name+'.sv'), root/(name+'-pp.sv')
            path.write_text(text)
            run(name+'-preprocess', ['/usr/bin/iverilog', '-g2012', '-E',
                *['-D'+f for f in FLAGS], '-o', pp, path])
            leaves.append(leaf(pp.read_text(), name, name == 'candidate'))
        instances = '\n'.join(name+' u'+str(i)+'('+','.join('.'+p+'('+p+')' for p in INPUTS)+
            ',.c_rdata(data['+str(i)+']));' for i, name in enumerate(('control', 'candidate')))
        variants = {'positive': leaves[1],
            'reverse_kind': leaves[1].replace('code_payload_access ? response_kind_code',
                                            '!code_payload_access ? response_kind_code'),
            'lost_primary_owner': leaves[1].replace('response_kind_rd_owner && !rd_code_q', "1'b0"),
            'lost_early_strobes': leaves[1].replace('(c_wstrb == early_wstrb_q);', "1'b1;"),
            'lost_stream': leaves[1].replace('if (stream_path) begin', "if (1'b0) begin")}
        assert len(set(variants.values())) == 5
        for name, variant in variants.items():
            path, binary = root/(name+'-leaf.sv'), root/(name+'.vvp')
            path.write_text(leaves[0]+variant+TB.replace('INSTANCES', instances))
            run(name+'-build', ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', binary, path], timeout=15)
            run(name, ['/usr/bin/vvp', binary], 0 if name == 'positive' else 1,
                'RESPONSE-KIND-OK' if name == 'positive' else 'RESPONSE-KIND-DATA')
        for name in ('positive', 'reverse_kind', 'lost_stream'):
            path = root/(name+'.smt2')
            path.write_text(recipe.formal(None if name == 'positive' else name))
            result = run('formal-'+name, ['/usr/bin/z3', path], timeout=5)
            assert result.strip() == ('unsat' if name == 'positive' else 'sat')
    except Exception as error:
        errors.append(repr(error))
    unchanged = all(sha(path) == value for path, value in pins.items())
    result = dict(passed=not errors and unchanged, errors=errors, pins_unchanged=unchanged,
        pins=pins, rows=rows, seconds=time.monotonic()-started, invocation=os.environ['INVOCATION_ID'],
        artifacts={p.name:sha(p) for p in root.iterdir() if p.is_file()},
        sequential_cache=False, whole_core=False, timing_verified=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins', 'artifacts', 'rows')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
