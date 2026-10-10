#!/usr/bin/env python3
"""Share the existing 83 /7 read-only CMP grammar with byte opcode 80 /7."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG='VEN_FAST_BYTE_MEM_CMP'
TARGET='rtl/core/decode.sv'
NORMALIZE='''`ifdef VEN_FAST_BYTE_MEM_CMP
    // 80 shares 83's checked read-only memory grammar and existing U ALU.
    // Byte immediate is unsigned; 83's sign extension is only for dwords.
    // Register forms retain AH..BH parent dependencies, never ESP..EDI.
    if (b0 == 8'h80 && d.simple) begin
      d.w8 = 1'b1;
      d.imm = {24'd0,d.imm[7:0]};
      if (mod == 2'b11) begin
        d.dst = fp_byte_parent(rm); d.src = d.dst;
        d.dst_hi8 = rm[2]; d.src_hi8 = rm[2];
        d.reads = _onehot(d.dst);
        d.writes = d.wreg ? _onehot(d.dst) : 8'd0;
      end
    end
`endif
'''


def transform(text):
    if FLAG in text:raise ValueError('already applied')
    first=text.index("        8'h80: begin\n")
    end=text.index("        8'h84: begin\n",first)
    text=text[:first]+'`ifndef '+FLAG+'\n'+text[first:end]+'`endif\n'+text[end:]
    anchor="        8'h83: begin\n"
    assert text.count(anchor)==1
    text=text.replace(anchor,"`ifdef "+FLAG+"\n        8'h83, 8'h80: begin\n`else\n"+anchor+'`endif\n')
    anchor='    return d;\n'
    assert text.count(anchor)==1
    text=text.replace(anchor,NORMALIZE+anchor)
    anchor='endmodule : decode'
    assert text.count(anchor)==1
    return text.replace(anchor,'`ifdef '+FLAG+'\n`ifndef VEN_FAST_BYTE_ALU\n'
        '  initial $fatal(1,"byte memory CMP requires byte ALU support");\n`endif\n`endif\n'+anchor)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();raw=a.source.read_bytes();changed=transform(raw.decode()).encode()
    assert a.source.resolve()!=a.out.resolve()
    with a.out.open('xb') as f:f.write(changed)
    assert a.source.read_bytes()==raw
    print(json.dumps(dict(source_sha256=hashlib.sha256(raw).hexdigest(),
        candidate_sha256=hashlib.sha256(changed).hexdigest(),production_changed=False)))
