#!/usr/bin/env python3
"""Small Icarus source-extracted mux miter; not a whole-cache or core gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_payload_code_hint as recipe

PORTS = '''input wire c_req,c_we,c_code,c_payload_code,cacheable,golden,stream_path,
rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q,
input wire [31:0] c_addr,rd_addr_q,early_addr_q,fbase,early_rdata_q,
input wire [31:5] shadow_line_addr_q,
input wire [3:0] c_wstrb,early_wstrb_q,
input wire [1:0] st,
input wire [511:0] rd_window_q,
input wire [255:0] shadow_line_q,code_line_q,
input wire [287:0] bp_line_x,
output reg [31:0] c_rdata,
output wire [31:0] c_rdata_hi,
output wire code_access,rd_match,early_match,code_payload_select,
shadow_payload_select,shadow_high_payload_select'''


def statement(source, name):
    match = re.search(r'\b(?:assign|wire)\s+'+re.escape(name)+r'\s*=', source)
    assert match, name
    end = source.index(';', match.start())+1
    return re.sub(r'^wire\b', 'assign', source[match.start():end])


def leaf(source, name, candidate):
    # Resolve the proposal's conditional branches BEFORE extracting statements:
    # one guarded declaration intentionally shares its unguarded continuation.
    source = recipe.select_hint_branch(source, candidate)
    names = ['code_access', 'rd_match', 'early_match', 'code_payload_select',
             'shadow_payload_select', 'shadow_high_payload_select', 'c_rdata_hi']
    if candidate:
        names += ['code_payload_access', 'rd_payload_match', 'early_payload_match']
    declarations = '\nwire code_payload_access,rd_payload_match,early_payload_match;\n' if candidate else '\n'
    # Extract the actual registered payload expression with its original guards,
    # not the separate old-value assertion or asynchronous diagnostic variant.
    start = source.index('    c_rdata =', source.index('// an armed but unmatched fill'))
    end = source.index('    // Use one primary-window byte selector', start)
    mux = source[start:end]
    stream = "      c_rdata = rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];"
    assert source.count(stream) == 1
    return ('module '+name+'('+PORTS+');\nlocalparam [1:0] L1_BYP=3;'+declarations+
            '\n'.join(statement(source, signal) for signal in names)+
            '\nalways @* begin\n'+mux+'\nif (stream_path) begin\n'+stream+'\nend\nend\nendmodule\n')


TB = r'''
module tb;
reg enabled,request,cur_is_d,seam,smram,route,drain,c_we;
wire mem_code,mem_payload_code;
CORE_ASSIGNMENTS
wire c_code=enabled && mem_code;
wire c_payload_code=enabled && mem_payload_code;
wire c_req=seam && enabled && request && !smram && !route && !drain;
reg cacheable,golden,stream_path,rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q;
reg [31:0] c_addr,rd_addr_q,early_addr_q,fbase,early_rdata_q;
reg [31:5] shadow_line_addr_q;
reg [3:0] c_wstrb,early_wstrb_q;
reg [1:0] st;
reg [511:0] rd_window_q;
reg [255:0] shadow_line_q,code_line_q;
reg [287:0] bp_line_x;
wire [31:0] data[0:1],high[0:1];
wire access_bit[0:1],rd[0:1],early[0:1],code_sel[0:1],shadow_sel[0:1],high_sel[0:1];
INSTANCES
integer consumed=0, code_n=0, shadow_n=0, early_n=0, stream_n=0,bypass_n=0,primary_n=0;
initial begin
  for (integer i=0;i<262144;i=i+1) begin
    {enabled,request,cur_is_d,seam,smram,route,drain,c_we}=i[7:0];
    {cacheable,golden,stream_path,rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q}=$random;
    c_addr=$random; c_wstrb=$random; st=$random; fbase=$random;
    // Exercise aligned code words and owner matches deliberately, not only
    // the overwhelmingly unmatched addresses in a uniform 32-bit random test.
    if (i[8]) begin c_addr[1:0]=0; c_wstrb=i[9] ? 4'hf : 4'h0; end
    rd_addr_q=i[10] ? c_addr : c_addr^32'h40;
    early_addr_q=i[11] ? c_addr : c_addr^32'h20;
    early_wstrb_q=i[12] ? c_wstrb : c_wstrb^4'hf;
    shadow_line_addr_q=i[13] ? c_addr[31:5] : c_addr[31:5]^27'h1;
    early_rdata_q=$random;
    for (integer b=0;b<16;b=b+1) rd_window_q[b*32+:32]=$random;
    for (integer b=0;b<8;b=b+1) begin shadow_line_q[b*32+:32]=$random; code_line_q[b*32+:32]=$random; end
    for (integer b=0;b<9;b=b+1) bp_line_x[b*32+:32]=$random;
    #1;
    // All original control predicates must match even on idle/denied edges.
    if ({access_bit[0],rd[0],early[0]} !== {access_bit[1],rd[1],early[1]})
      $fatal(1,"PAYLOAD-HINT-CONTROL i=%0d",i);
    // Stronger than ACK-only: payload equivalence on every admitted read,
    // including reads stalled by arbitrary cache owner state.
    if (c_req && !c_we) begin
      consumed=consumed+1;
      if (data[0] !== data[1] || high[0] !== high[1] ||
          {code_sel[0],shadow_sel[0],high_sel[0]} !== {code_sel[1],shadow_sel[1],high_sel[1]})
        $fatal(1,"PAYLOAD-HINT-DATA i=%0d",i);
      if (stream_path) stream_n=stream_n+1;
      else if (st==3) bypass_n=bypass_n+1;
      else if (early[0]) early_n=early_n+1;
      else if (code_sel[0]) code_n=code_n+1;
      else if (shadow_sel[0]) shadow_n=shadow_n+1;
      else primary_n=primary_n+1;
    end
  end
  if (!(consumed>0 && code_n>0 && shadow_n>0 && early_n>0 && stream_n>0 && bypass_n>0 && primary_n>0))
    $fatal(1,"PAYLOAD-HINT-COVERAGE");
  $display("PAYLOAD-HINT-OK clocks=262144 reads=%0d code=%0d shadow=%0d early=%0d stream=%0d bypass=%0d primary=%0d",
      consumed,code_n,shadow_n,early_n,stream_n,bypass_n,primary_n);
  $finish;
end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    before = {name: (parent/name).read_text() for name in recipe.HASHES}
    after = recipe.transform(before)
    root.mkdir()

    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def sha(path):
        with Path(path).open('rb') as stream:
            return hashlib.file_digest(stream, 'sha256').hexdigest()

    pins = {str(parent/name): digest for name, digest in recipe.HASHES.items()}
    for path in (Path(__file__), Path(recipe.__file__), Path('/usr/bin/iverilog'), Path('/usr/bin/vvp')):
        pins[str(path.resolve())] = sha(path)
    for name, text in after.items():
        path = root/'candidate'/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        pins[str(path)] = sha(path)
    names = re.findall(r'\b(?:c_req|c_we|c_code|c_payload_code|cacheable|golden|stream_path|rd_armed|rd_code_q|early_armed|early_code_q|shadow_valid_q|c_addr|rd_addr_q|early_addr_q|fbase|early_rdata_q|shadow_line_addr_q|c_wstrb|early_wstrb_q|st|rd_window_q|shadow_line_q|code_line_q|bp_line_x)\b', PORTS.split('output reg')[0])
    assert len(names) == len(set(names)) == 25
    instances = []
    for index, module in enumerate(('control', 'candidate')):
        wires = [f'.{name}({name})' for name in names]
        wires += [f'.{name}({signal}[{index}])' for name, signal in (
            ('c_rdata', 'data'), ('c_rdata_hi', 'high'), ('code_access', 'access_bit'), ('rd_match', 'rd'),
            ('early_match', 'early'), ('code_payload_select', 'code_sel'),
            ('shadow_payload_select', 'shadow_sel'), ('shadow_high_payload_select', 'high_sel'))]
        instances.append(module+' u'+str(index)+'('+','.join(wires)+');')
    core = '\n'.join(statement(after['rtl/core/core.sv'], name).replace('mem_req', 'request')
                     for name in ('mem_code', 'mem_payload_code'))
    tb = TB.replace('CORE_ASSIGNMENTS', core).replace('INSTANCES', '\n'.join(instances))
    baseline = leaf(before['rtl/mem/ven_l1d.sv'], 'control', False)
    candidate = leaf(after['rtl/mem/ven_l1d.sv'], 'candidate', True)
    variants = dict(positive=candidate,
        wrong_kind=candidate.replace('c_payload_code && cacheable', '!c_payload_code && cacheable'),
        early_wrong_owner=candidate.replace('(c_addr == early_addr_q) &&\n      (c_wstrb == early_wstrb_q)', "1'b1"),
        raw_hint_control=candidate.replace('code_access = c_code &&', 'code_access = c_payload_code &&'))
    assert len(set(variants.values())) == 4
    save('started.json', dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
        scope='source-extracted combinational mux only; not cache FSM, core, timing or gameplay acceptance'))
    begin = time.monotonic()
    rows = []
    phase = 'prepare'
    try:
        for name, variant in variants.items():
            source, binary = root/(name+'.sv'), root/(name+'.vvp')
            source.write_text(baseline+variant+tb)
            command = ['iverilog', '-g2012', '-s', 'tb', '-D'+recipe.FLAG,
                '-DVEN_L1D_CODE_BUFFER', '-DVEN_L1D_CODE_WORD_REUSE', '-DVEN_L1D_CODE_PAYLOAD_SELECT',
                '-DVEN_L1D_RESPONSE_PAYLOAD_SELECT', '-o', str(binary), str(source)]
            phase = name+' compile'
            with (root/(name+'-build.log')).open('x') as log:
                built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=20)
            assert built.returncode == 0, (name, 'compile failed', built.returncode)
            phase = name+' simulation'
            with (root/(name+'.log')).open('x') as log:
                # A bounded vvp -v diagnostic measured 41,269 advancing time
                # steps in five seconds: the 262,144-vector sweep needs ~32s,
                # not the original 30s. No vector or check is removed.
                done = subprocess.run(['vvp', str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=50)
            text = (root/(name+'.log')).read_text()
            rows.append(dict(name=name, native_exit=done.returncode, log=text, command=command,
                             source_sha256=sha(source), binary_sha256=sha(binary)))
            assert (done.returncode == 0 and 'PAYLOAD-HINT-OK' in text) if name == 'positive' else (
                done.returncode != 0 and ('PAYLOAD-HINT-CONTROL' in text or 'PAYLOAD-HINT-DATA' in text)), (name, text)
        phase = 'input rehash'
        assert all(sha(path) == digest for path, digest in pins.items())
    except Exception as error:
        save('failure.json', dict(passed=False, phase=phase, error=repr(error), rows=rows,
            timeout=isinstance(error, subprocess.TimeoutExpired), seconds=time.monotonic()-begin,
            evidence={str(path.relative_to(root)): sha(path) for path in root.iterdir()
                      if path.is_file()}, full_cache_verified=False, whole_core_verified=False))
        raise
    result = dict(passed=True, rows=rows, pins_unchanged=True, seconds=time.monotonic()-begin,
                  full_cache_verified=False, whole_core_verified=False, timing_verified=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
