"""Replace the pinned ALU's serial RCL/RCR loops with bounded ring rotations.

Pure source recipe: never edits the parent or changes decoder/admission rules.
The six-bit helper contract includes saturation at 32 steps (not count & 31).
"""
import hashlib


PARENT = '3001ae4833b49f9b14d31c6685add9a81c0949443c25681b76fa15afdf9e3058'
ANCHOR = '  function automatic logic [31:0] shrot_result('
HELPER = '''  // RCL/RCR rotate the operand and carry together: 9, 17 or 33 bits.
  // The old helpers execute min(cnt,32) single-bit iterations. Preserve that
  // full six-bit contract, including counts 32..63, although x86 callers mask
  // their architectural count to five bits. Six fixed-distance stages replace
  // 32 serial conditional stages; every distance/modulus below is a constant
  // after loop unrolling. There is no run-time divider or added clock cycle.
  function automatic logic [32:0] shrot_carry_ring(
      input logic right, input logic [31:0] v, input logic [5:0] cnt,
      input logic cfin, input logic [2:0] w);
    logic [8:0] r9;
    logic [16:0] r17;
    logic [32:0] r33;
    logic [5:0] steps;
    begin
      r9 = {cfin,v[7:0]}; r17 = {cfin,v[15:0]}; r33 = {cfin,v};
      steps = cnt[5] ? 6'd32 : cnt;
      // A relational comparison with an X/Z count was false in each old
      // procedural if. Keep that simulation behavior; this is constant true
      // for every binary six-bit count and disappears during synthesis.
      if (cnt <= 6'd63) begin
        for (int stage = 0; stage < 6; stage++) begin
          if (steps[stage]) begin
            if (right) begin
              r9 = (r9 >> ((1 << stage) % 9)) |
                   (r9 << (9 - ((1 << stage) % 9)));
              r17 = (r17 >> ((1 << stage) % 17)) |
                    (r17 << (17 - ((1 << stage) % 17)));
              r33 = (r33 >> ((1 << stage) % 33)) |
                    (r33 << (33 - ((1 << stage) % 33)));
            end else begin
              r9 = (r9 << ((1 << stage) % 9)) |
                   (r9 >> (9 - ((1 << stage) % 9)));
              r17 = (r17 << ((1 << stage) % 17)) |
                    (r17 >> (17 - ((1 << stage) % 17)));
              r33 = (r33 << ((1 << stage) % 33)) |
                    (r33 >> (33 - ((1 << stage) % 33)));
            end
          end
        end
      end
      case (w)
        3'd1: return {r9[8],24'd0,r9[7:0]};
        3'd2: return {r17[16],16'd0,r17[15:0]};
        default: return r33;
      endcase
    end
  endfunction

'''
OLD_RESULT = '''        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end end
'''
NEW_RESULT = '''        3'd2,3'd3: begin
          ring = shrot_carry_ring(subop[0],v,cnt,cfin,w);
          x = ring[31:0];
        end
'''
OLD_CF = '''        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end shrot_cf=carry; end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end shrot_cf=carry; end
'''
NEW_CF = '''        3'd2,3'd3: begin
          ring = shrot_carry_ring(subop[0],v,cnt,cfin,w);
          shrot_cf = ring[32];
        end
'''
EDITS = (
    (ANCHOR, HELPER + ANCHOR),
    ('    logic [31:0] x; logic [5:0] bits, rot; logic carry, nc; int i; logic [4:0] ihi;',
     '    logic [31:0] x; logic [5:0] bits, rot; logic [4:0] ihi;\n    logic [32:0] ring;'),
    ('    logic [31:0] x,res; logic [5:0] bits; logic carry,nc; int i;',
     '    logic [31:0] x,res; logic [5:0] bits;\n    logic [32:0] ring;'),
    (OLD_RESULT, NEW_RESULT),
    (OLD_CF, NEW_CF),
)


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('carry-rotate parent drift')
    changed = source
    for old, new in EDITS:
        if changed.count(old) != 1:
            raise ValueError('carry-rotate edit anchor drift')
        changed = changed.replace(old, new)
    recovered = changed
    for old, new in reversed(EDITS):
        recovered = recovered.replace(new, old, 1)
    if recovered != source:
        raise ValueError('non-reversible carry-rotate edit')
    return changed
