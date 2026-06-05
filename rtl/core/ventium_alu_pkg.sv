// core/ventium_alu_pkg.sv — pure integer ALU datapath: result + EFLAGS
// computation and the width/flag helpers, extracted verbatim from intcore.sv
// (R1 modularization, docs/rtl-refactor-plan.md). These are PURE functions
// (no module state) so moving them here and calling them in place is
// bit-identical behavior.
//
// Holds the ALU-op encoding (the low 3 bits mirror the x86 ALU group order
// 0..7) the functions case on; the decoder imports this package to reference
// ALU_ADD..ALU_NOT when classifying opcodes.

package ventium_alu_pkg;

  // ALU op encoding (low 3 bits mirror the x86 ALU group order 0..7).
  localparam logic [4:0] ALU_ADD = 5'd0;
  localparam logic [4:0] ALU_OR  = 5'd1;
  localparam logic [4:0] ALU_ADC = 5'd2;
  localparam logic [4:0] ALU_SBB = 5'd3;
  localparam logic [4:0] ALU_AND = 5'd4;
  localparam logic [4:0] ALU_SUB = 5'd5;
  localparam logic [4:0] ALU_XOR = 5'd6;
  localparam logic [4:0] ALU_CMP = 5'd7;
  localparam logic [4:0] ALU_INC = 5'd8;
  localparam logic [4:0] ALU_DEC = 5'd9;
  localparam logic [4:0] ALU_TEST= 5'd10;
  localparam logic [4:0] ALU_MOV = 5'd11;
  localparam logic [4:0] ALU_NEG = 5'd12;
  localparam logic [4:0] ALU_NOT = 5'd13;
  // BCD/ASCII-adjust ops (review fidelity closure). These do NOT use the generic
  // alu_result()/flags_next() datapath — core.sv computes their AX result + flags
  // combinationally (matching QEMU helper_aaa/aas/daa/das/aam/aad exactly) and
  // overrides alu_out/flags_out. The encodings live here only so the decode can
  // classify them; the contiguous range 14..19 lets core.sv test "is BCD".
  localparam logic [4:0] ALU_AAA = 5'd14;  // 0x37 ASCII adjust after add
  localparam logic [4:0] ALU_AAS = 5'd15;  // 0x3F ASCII adjust after sub
  localparam logic [4:0] ALU_DAA = 5'd16;  // 0x27 decimal adjust after add
  localparam logic [4:0] ALU_DAS = 5'd17;  // 0x2F decimal adjust after sub
  localparam logic [4:0] ALU_AAM = 5'd18;  // 0xD4 ib ASCII adjust after mul
  localparam logic [4:0] ALU_AAD = 5'd19;  // 0xD5 ib ASCII adjust before div

  // ===========================================================================
  // Width helpers
  // ===========================================================================
  function automatic logic [31:0] wmask(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return {24'd0, v[7:0]};
    else if (w==3'd2) return {16'd0, v[15:0]};
    else return v;
  endfunction
  function automatic logic sbit(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return v[7]; else if (w==3'd2) return v[15]; else return v[31];
  endfunction
  // second-highest bit (MSB-1) of width w
  function automatic logic sbit2(input logic [31:0] v, input logic [2:0] w);
    if (w==3'd1) return v[6]; else if (w==3'd2) return v[14]; else return v[30];
  endfunction
  function automatic logic parity8(input logic [7:0] v); return ~^v; endfunction

  // ===========================================================================
  // ALU result + EFLAGS at width w
  // ===========================================================================
  function automatic logic [31:0] alu_result(input logic [4:0] op, input logic [31:0] a,
                                             input logic [31:0] b, input logic cfin);
    unique case (op)
      ALU_ADD, ALU_INC: alu_result=a+b;
      ALU_SUB, ALU_CMP, ALU_DEC: alu_result=a-b;
      ALU_AND, ALU_TEST: alu_result=a&b;
      ALU_OR:  alu_result=a|b;
      ALU_XOR: alu_result=a^b;
      ALU_MOV: alu_result=b;
      ALU_ADC: alu_result=a+b+{31'd0,cfin};
      ALU_SBB: alu_result=a-b-{31'd0,cfin};
      ALU_NEG: alu_result=32'd0-a;
      ALU_NOT: alu_result=~a;
      default: alu_result=a;
    endcase
  endfunction

  function automatic logic [31:0] flags_next(input logic [4:0] op, input logic [31:0] a,
                                             input logic [31:0] b, input logic [31:0] res_full,
                                             input logic [31:0] cur, input logic [2:0] w);
    logic cf,pf,af,zf,sf,of;
    logic [31:0] fl,res,am,bm;
    logic [32:0] uadd,usub,uadc,usbb;
    int msb, cpos;
    begin
      res=wmask(res_full,w); am=wmask(a,w); bm=wmask(b,w);
      msb=(w==3'd1)?7:((w==3'd2)?15:31);
      cpos=(w==3'd1)?8:((w==3'd2)?16:32);
      zf=(res==32'd0); sf=sbit(res,w); pf=parity8(res[7:0]);
      uadd={1'b0,am}+{1'b0,bm};
      usub={1'b0,am}-{1'b0,bm};
      uadc={1'b0,am}+{1'b0,bm}+{32'd0,cur[0]};
      usbb={1'b0,am}-{1'b0,bm}-{32'd0,cur[0]};
      cf=cur[0]; af=cur[4]; of=cur[11];
      unique case (op)
        ALU_ADD: begin cf=uadd[cpos]; af=(am[4]^bm[4]^res[4]); of=(~(am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_ADC: begin cf=uadc[cpos]; af=(am[4]^bm[4]^res[4]); of=(~(am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_SUB, ALU_CMP: begin cf=usub[cpos]; af=(am[4]^bm[4]^res[4]); of=((am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_SBB: begin cf=usbb[cpos]; af=(am[4]^bm[4]^res[4]); of=((am[msb]^bm[msb])&(am[msb]^res[msb])); end
        ALU_INC: begin cf=cur[0]; af=(am[4]^bm[4]^res[4]); of=(res[msb] && !am[msb]); end
        ALU_DEC: begin cf=cur[0]; af=(am[4]^bm[4]^res[4]); of=(!res[msb] && am[msb]); end
        ALU_NEG: begin cf=(am!=32'd0); af=(am[4]^res[4]); of=(am[msb] & res[msb]); end
        ALU_AND, ALU_OR, ALU_XOR, ALU_TEST: begin cf=1'b0; af=1'b0; of=1'b0; end
        default: begin cf=cur[0]; af=cur[4]; of=cur[11]; end
      endcase
      fl=cur & 32'hFFFF_F72A;
      fl[0]=cf; fl[2]=pf; fl[4]=af; fl[6]=zf; fl[7]=sf; fl[11]=of; fl[1]=1'b1;
      return fl;
    end
  endfunction

  // ===========================================================================
  // Shift/rotate result + CF
  // ===========================================================================
  function automatic logic [31:0] shrot_result(input logic [2:0] subop, input logic [31:0] v,
                                               input logic [5:0] cnt, input logic cfin, input logic [2:0] w);
    logic [31:0] x; logic [5:0] bits; logic carry, nc; int i; logic [4:0] ihi;
    begin
      x=wmask(v,w); bits=(w==3'd1)?6'd8:((w==3'd2)?6'd16:6'd32);
      ihi=5'(bits-6'd1);
      unique case (subop)
        3'd4,3'd6: x = wmask(x << cnt, w);
        3'd5:      x = x >> cnt;
        3'd7: begin
          if (w==3'd1)      x=$unsigned($signed({{24{v[7]}},v[7:0]})>>>cnt);
          else if (w==3'd2) x=$unsigned($signed({{16{v[15]}},v[15:0]})>>>cnt);
          else              x=$unsigned($signed(v)>>>cnt);
          x=wmask(x,w);
        end
        3'd0: for (i=0;i<32;i++) if (i<cnt) x=wmask((x<<1)|{31'd0,x[ihi]},w);
        3'd1: for (i=0;i<32;i++) if (i<cnt) x=wmask((x>>1)|({31'd0,x[0]}<<(bits-6'd1)),w);
        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end end
        default: ;
      endcase
      return wmask(x,w);
    end
  endfunction

  function automatic logic shrot_cf(input logic [2:0] subop, input logic [31:0] v,
                                    input logic [5:0] cnt, input logic cfin, input logic [2:0] w);
    logic [31:0] x,res; logic [5:0] bits; logic carry,nc; int i;
    logic [4:0] ihi, ilo, ic;
    begin
      x=wmask(v,w); bits=(w==3'd1)?6'd8:((w==3'd2)?6'd16:6'd32);
      ihi=5'(bits-6'd1);        // top bit index of the width
      ilo=5'(bits-cnt);         // SHL CF source bit
      ic =5'(cnt-6'd1);         // SHR/SAR CF source bit
      unique case (subop)
        3'd4,3'd6: shrot_cf=(cnt==0)?cfin:x[ilo];
        3'd5,3'd7: shrot_cf=(cnt==0)?cfin:x[ic];
        3'd0: begin res=shrot_result(3'd0,v,cnt,cfin,w); shrot_cf=(cnt==0)?cfin:res[0]; end
        3'd1: begin res=shrot_result(3'd1,v,cnt,cfin,w); shrot_cf=(cnt==0)?cfin:res[ihi]; end
        3'd2: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[ihi]; x=wmask((x<<1)|{31'd0,carry},w); carry=nc; end shrot_cf=carry; end
        3'd3: begin carry=cfin; for(i=0;i<32;i++) if(i<cnt) begin nc=x[0]; x=wmask((x>>1)|({31'd0,carry}<<(bits-6'd1)),w); carry=nc; end shrot_cf=carry; end
        default: shrot_cf=cfin;
      endcase
    end
  endfunction

  // SHLD/SHRD (16/32-bit only)
  function automatic logic [31:0] shld_result(input logic is_shrd, input logic [31:0] dst,
                                              input logic [31:0] src, input logic [5:0] cnt, input logic [2:0] w);
    logic [31:0] r; logic [5:0] bits;
    begin
      bits=(w==3'd2)?6'd16:6'd32;
      if (cnt==0) r=dst;
      else if (is_shrd) r=(dst>>cnt)|(src<<(bits-cnt));
      else              r=(dst<<cnt)|(src>>(bits-cnt));
      return wmask(r,w);
    end
  endfunction
  function automatic logic shld_cf(input logic is_shrd, input logic [31:0] dst,
                                   input logic [5:0] cnt, input logic [2:0] w);
    logic [5:0] bits; logic [4:0] ilo, ic;
    begin
      bits=(w==3'd2)?6'd16:6'd32;
      ilo=5'(bits-cnt); ic=5'(cnt-6'd1);
      if (cnt==0) shld_cf=1'b0;
      else if (is_shrd) shld_cf=dst[ic];
      else shld_cf=dst[ilo];
    end
  endfunction

endpackage : ventium_alu_pkg
