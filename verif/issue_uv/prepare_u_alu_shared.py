"""Propose one shared U arithmetic result/flag expression; never edits inputs.

The exact-source recipe preserves the U-pipe interface, shifter and cycle
behavior. Native validation and measured synthesis remain separate gates.
"""
import hashlib

PARENT = 'a93bbe5f4a29df896fd4be1d92807889030d432ab6bb1ef6d1b9b7712e5ff222'
ANCHOR = '  // U datapath (reuse the shared helpers; results are bit-identical to slow).'
HELPER = '''  // Shared 33-bit add/sub/ADC/SBB/NEG result and flags. No new clock stage.
  function automatic logic [63:0] fp_result_flags(
      input logic [4:0] op, input logic [31:0] a, b, cur,
      input logic [2:0] width);
    logic [31:0] am,bm,aa,bb,full,res,fl;
    logic [32:0] arithmetic;
    logic subtract,cin,cf,af,of;
    int msb,cpos;
    begin
      am=wmask(a,width); bm=wmask(b,width);
      aa=(op==ALU_NEG)?32'd0:am;
      bb=(op==ALU_NEG)?am:bm;
      subtract=(op==ALU_SUB || op==ALU_CMP || op==ALU_DEC ||
                op==ALU_SBB || op==ALU_NEG);
      cin=subtract ? !(op==ALU_SBB && cur[0]) : (op==ALU_ADC && cur[0]);
      // Complement all 33 bits for subtraction: bit cpos is the borrow bit
      // for 8/16/32-bit masked operands, not the inverted final carry-out.
      arithmetic={1'b0,aa}+({1'b0,bb}^{33{subtract}})+{32'd0,cin};
      case(op)
        ALU_ADD,ALU_INC,ALU_SUB,ALU_CMP,ALU_DEC,ALU_ADC,ALU_SBB,ALU_NEG:
          full=arithmetic[31:0];
        ALU_AND,ALU_TEST: full=am&bm;
        ALU_OR: full=am|bm;
        ALU_XOR: full=am^bm;
        ALU_MOV: full=bm;
        ALU_NOT: full=~am;
        default: full=am;
      endcase
      res=wmask(full,width);
      msb=(width==1)?7:((width==2)?15:31);
      cpos=(width==1)?8:((width==2)?16:32);
      cf=cur[0]; af=cur[4]; of=cur[11];
      case(op)
        ALU_ADD,ALU_ADC: begin
          cf=arithmetic[cpos]; af=am[4]^bm[4]^res[4];
          of=~(am[msb]^bm[msb])&(am[msb]^res[msb]);
        end
        ALU_SUB,ALU_CMP,ALU_SBB: begin
          cf=arithmetic[cpos]; af=am[4]^bm[4]^res[4];
          of=(am[msb]^bm[msb])&(am[msb]^res[msb]);
        end
        ALU_INC: begin
          af=am[4]^bm[4]^res[4]; of=res[msb]&&!am[msb];
        end
        ALU_DEC: begin
          af=am[4]^bm[4]^res[4]; of=!res[msb]&&am[msb];
        end
        ALU_NEG: begin cf=(am!=0); af=am[4]^res[4]; of=am[msb]&res[msb]; end
        ALU_AND,ALU_OR,ALU_XOR,ALU_TEST: begin cf=0; af=0; of=0; end
        default: ;
      endcase
      fl=cur&32'hffff_f72a;
      fl[0]=cf; fl[2]=~^res[7:0]; fl[4]=af; fl[6]=(res==0);
      fl[7]=sbit(res,width); fl[11]=of; fl[1]=1;
      return {fl,full};
    end
  endfunction

'''
OLD = '''    u_alu   = alu_result(u_d.alu_op, u_a_w, u_b_w, eflags[0]);
    // task #56 step H: the width argument was HARDCODED 3'd4 (32-bit) while the slow
    // path passes q_w (core.sv:2034). A 16-bit op therefore set ZF/SF/CF/OF from the
    // full 32-bit result -> wrong conditional branches -> guest divergence (UPDATE 279).
    // flags_next already handles width; it was simply never told.
    u_flags = flags_next(u_d.alu_op, u_a_w, u_b_w, u_alu, eflags, fp_operand_width(u_d));
'''
NEW = '''    // Result and flag carry/borrow use the same arithmetic expression.
    // Preserve the full, unmasked result and the original width/flag policy.
    {u_flags,u_alu} = fp_result_flags(u_d.alu_op, u_a_w, u_b_w,
                                    eflags, fp_operand_width(u_d));
'''
EDITS = ((ANCHOR, HELPER+ANCHOR), (OLD, NEW))


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('shared U ALU parent drift')
    result = source
    for old, new in EDITS:
        if result.count(old) != 1:
            raise ValueError('shared U ALU anchor drift')
        result = result.replace(old, new)
    recovered = result
    for old, new in reversed(EDITS):
        recovered = recovered.replace(new, old, 1)
    if recovered != source:
        raise ValueError('non-reversible shared U ALU edit')
    return result
