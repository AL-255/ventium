`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/decode.sv — M4/M5 fast-path variable-length x86 decoder.
//
// Extracted VERBATIM from intcore.sv (R1 modularization phase 3,
// docs/rtl-refactor-plan.md). This is the fast-path decoder the dual-issue
// pipeline uses: it recognises the simple/pairable instruction subset directly
// (MOV/ALU/INC-DEC/LEA/load/shift/Jcc + a cycle-mode x87 reg-form whitelist) and
// emits the decoded-uop struct (fpd_t) consumed by the U/V issue logic. Anything
// it does not recognise leaves d.simple=0 and the core falls back to the slow
// multi-cycle FSM. Pure combinational: bytes (+ EFLAGS, + cycle_mode) -> fpd_t.
//
// IF (docs/rtl-refactor-plan.md §6 decode.sv): instruction bytes in -> decoded
// uop struct + length out. b0..b6 are the fixed fast-path decode bytes; flags_in is
// the current EFLAGS (for the architectural Jcc taken decision); cycle_mode
// gates the x87 reg-form whitelist exactly as the in-line version did (func runs
// keep FP on the slow FSM). The fpd_t carries .len (decoded length).
//
// fp_decode / _onehot below are moved BIT-FOR-BIT from intcore.sv; the only
// change is that they now live in this module's scope (cycle_mode is this
// module's input port, read by the function exactly as it read intcore's port).

module decode
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
(
    input  logic [7:0]  ib0,
    input  logic [7:0]  ib1,
    input  logic [7:0]  ib2,
    input  logic [7:0]  ib3,
    input  logic [7:0]  ib4,
    input  logic [7:0]  ib5,
    input  logic [7:0]  ib6,
    input  logic [31:0] iflags,
    // task #56 step C: the 16-bit-default flag (core.sv:770, def16 = sys_mode && !cs_d).
    // decode.sv was written for 32-bit flat code and had NO operand-size concept at all,
    // which is precisely what core_fastpath.svh:288's sys_mode bail-out exists to avoid.
    input  logic        def16,
    input  logic        cycle_mode,
    output fpd_t        uop
);

  // ---- fast-path decoder (moved verbatim from intcore.sv) -------------------
  function automatic fpd_t fp_decode(input logic [7:0] b0, input logic [7:0] b1,
                                     input logic [7:0] b2, input logic [7:0] b3,
                                     input logic [7:0] b4, input logic [7:0] b5,
                                     input logic [7:0] b6,
                                     input logic [31:0] flags_in);
    fpd_t d;
    logic [1:0] mod; logic [2:0] reg_f, rm;
    logic checked_add_opcode;
    logic fp_mem_load, fp_mem_integer, fp_mem_wide;
    begin
      d = '{default:'0};
      d.alu_op = ALU_ADD; d.len = 4'd1;
      // task #56 step F: for UNPREFIXED instructions eff_opsize == def16, so w16 follows it
      // directly. decode.sv still does not recognise prefixes (an unrecognised prefix byte lands
      // as b0 and yields d.simple=0), so every instruction that reaches an arm below is
      // unprefixed by construction -- which makes this exact, not an approximation.
      d.w16 = def16;

      mod = b1[7:6]; reg_f = b1[5:3]; rm = b1[2:0];
      fp_mem_load=1'b0; fp_mem_integer=1'b0; fp_mem_wide=1'b0;
`ifdef VEN_FP_MEM_LOADS
      // Only consumed by the shared/direct memory descriptor below. No new
      // AGU, operand sequencer, conversion unit, or speculative read path.
      if (b0==8'hD9 && reg_f==3'd0) fp_mem_load=1'b1;       // FLD m32
      if (b0==8'hDD && reg_f==3'd0) begin
        fp_mem_load=1'b1; fp_mem_wide=1'b1;                 // FLD m64
      end
      if (b0==8'hDB && reg_f==3'd0) begin
        fp_mem_load=1'b1; fp_mem_integer=1'b1;              // FILD m32
      end
      if (b0==8'hDF && reg_f==3'd5) begin
        fp_mem_load=1'b1; fp_mem_integer=1'b1; fp_mem_wide=1'b1; // FILD m64
      end
`endif
      checked_add_opcode = (b0 == 8'h03);
`ifdef VEN_FAST_MEM_ALU
      // Register-destination dword ALU reads reuse ADD's checked transaction
      // and existing U ALU. CMP keeps its separate read-only descriptor arm.
      checked_add_opcode = (b0[7:6]==2'b00 && b0[2:0]==3'b011 &&
                            b0[5:3]!=3'b111);
`endif
`ifdef VEN_FAST_MEM_ADC
      checked_add_opcode = checked_add_opcode || (b0 == 8'h13);
`endif
      unique casez (b0)
        // ---- MOV r32, imm32 (B8+r) -------------------------------------------
        8'b1011_1???: begin
          d.simple=1'b1; d.len=def16?4'd3:4'd5; d.alu_op=ALU_MOV; d.wreg=1'b1; d.use_imm=1'b1;
          d.dst=b0[2:0]; d.imm=def16?{16'd0,b2,b1}:{b4,b3,b2,b1};
          d.writes={5'd0, _onehot(b0[2:0])}[7:0];
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
        // ---- ALU r/m32, r32 (00/08/.. /r reg form) : add/or/adc/sbb/and/sub/xor
        // CMP (39 /r) is intentionally excluded: its memory forms have a
        // dedicated checked-read arm below.  Keeping case items disjoint is
        // essential here -- a later arm cannot override a matched casez item.
        8'h01, 8'h09, 8'h11, 8'h19, 8'h21, 8'h29, 8'h31: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op={2'b00,b0[5:3]}; d.wflags=1'b1;
            d.dst=rm; d.src=reg_f;
            d.wreg=(b0[5:3]!=3'b111);                 // CMP writes no reg
            d.reads = _onehot(rm) | _onehot(reg_f);
            d.writes = d.wreg ? _onehot(rm) : 8'd0;
            // ADC(op2)/SBB(op3) are PU (U-only-pairable, p5model pclass=PU): they
            // may LEAD a pair but must NEVER fill the V slot — both because P5
            // forbids it and because the V ALU path has no CF forwarding, so an
            // adc/sbb in V would consume the STALE architectural carry and
            // corrupt arch state. pairs_second=0 keeps them U-only.
            d.pairs_first=1'b1;
            d.pairs_second=!(b0[5:3]==3'b010 || b0[5:3]==3'b011);
          end
        end
        // ---- ALU r32, r/m32 (02/0A/.. /r reg form) ---------------------------
        // CMP (3B /r) is likewise handled below for its checked memory forms.
        8'h03, 8'h0B, 8'h13, 8'h1B, 8'h23, 8'h2B, 8'h33: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op={2'b00,b0[5:3]}; d.wflags=1'b1;
            d.dst=reg_f; d.src=rm; d.wreg=(b0[5:3]!=3'b111);
            d.reads = _onehot(rm) | _onehot(reg_f);
            d.writes = d.wreg ? _onehot(reg_f) : 8'd0;
            // ADC(op2)/SBB(op3) = PU (U-only-pairable); never fill V (see above).
            d.pairs_first=1'b1;
            d.pairs_second=!(b0[5:3]==3'b010 || b0[5:3]==3'b011);
          end
`ifdef VEN_FAST_MEM_ADD
          // Checked ADD r32,r/m32.  It shares the established U-side memory
          // packet: the read must complete before EFLAGS/GPR writeback, and a
          // miss, #PF, fragment, or executable flush retains the decoded
          // packet rather than re-reading this frontend window. The opt-in
          // VEN_FAST_MEM_ADC reuses these exact address forms, selecting ADC
          // and its U-only pairing class below. VEN_FAST_MEM_ALU additionally
          // admits OR/SBB/AND/SUB/XOR through this same address/response path.
          // The original selected forms fit the
          // six-byte decode window.  An independently gated seven-byte
          // SIB+disp32 forms appear below; an ESP destination remains on the
          // mature FSM. It needs a wider audit of the
          // pre-existing stack-pointer AGI accounting.
          else if (!def16 && checked_add_opcode && reg_f!=R_ESP && mod==2'b00 && rm==3'b101) begin
            // ADD r32,[disp32]: a literal DS offset, not an EBP base.
            d.simple=1'b1; d.is_mem=1'b1; d.len=4'd6;
            d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
            d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
            d.mem_disp={b5,b4,b3,b2};
            d.reads=_onehot(reg_f); d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && checked_add_opcode && reg_f!=R_ESP && rm!=3'b100 && !(mod==2'b00 && rm==3'b101)) begin
            // ADD r32,[base{+disp8|+disp32}].  EBP's disp forms select SS;
            // the address inputs appear in both reads and addr_mask so the
            // AGI and U/V RAW check describe the same operation.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd2;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.reads=_onehot(reg_f)|_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd3;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={{24{b2[7]}},b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b10: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd6;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={b5,b4,b3,b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
`ifdef VEN_FAST_MEM_ADD7
          end else if (!def16 && checked_add_opcode && reg_f!=R_ESP &&
                       mod==2'b00 && rm==3'b100 && b2[2:0]==3'b101) begin
            // SIB index*scale+disp32 has NO base. In particular, base field
            // 101 does not read EBP or select SS. Index 100 is also absent.
            // Reuse the same checked AGU/response packet as ordinary SIB.
            d.simple=1'b1; d.is_mem=1'b1; d.len=4'd7;
            d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
            d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
            d.mem_base_en=1'b0; d.mem_ss=1'b0;
            d.mem_index=b2[5:3]; d.mem_scale=b2[7:6];
            d.mem_index_en=(b2[5:3]!=3'b100);
            d.mem_disp={b6,b5,b4,b3};
            d.addr_mask=(b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0;
            d.reads=_onehot(reg_f)|d.addr_mask; d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
`endif
          end else if (!def16 && checked_add_opcode && reg_f!=R_ESP && rm==3'b100 && !(mod==2'b00 && b2[2:0]==3'b101)) begin
            // ADD r32,[base+index*scale{+disp8}].  An ESP index encodes no
            // index; ESP/EBP bases select SS.  The disp32 sibling is behind
            // VEN_FAST_MEM_ADD7 below because it needs the seventh fixed
            // frontend byte and a full uop-cache extent audit.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd3;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd4;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.mem_disp={{24{b3[7]}},b3};
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
`ifdef VEN_FAST_MEM_ADD7
              // ADD r32,[base+index*scale+disp32].  This is the remaining
              // ordinary 32-bit SIB form, not an address- or program-specific
              // special case.  `mod==2'b10` always supplies a concrete base;
              // unlike the mod=00 no-base encoding it therefore preserves the
              // same DS/SS selection and AGI dependency contract as the
              // existing no-disp/disp8 siblings.
              2'b10: begin
                d.simple=1'b1; d.is_mem=1'b1; d.len=4'd7;
                d.alu_op=ALU_ADD; d.wflags=1'b1; d.wreg=1'b1;
                d.dst=reg_f; d.src=reg_f; d.mem_lhs=1'b0;
                d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.mem_disp={b6,b5,b4,b3};
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
`endif
              default: ;
            endcase
          end
`endif
        end
        // ---- ALU eAX, imm32 (accumulator short forms 05/0D/15/1D/25/2D/35/3D) -
        // AP-500 fast-path coverage (review Action 6, batch 1): the accumulator-
        // immediate forms. Pure register/immediate semantics (no memory) — the
        // ALU op is b0[5:3] (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP); operand A = EAX,
        // operand B = imm32 (use_imm). Mirrors the 83 reg-form imm arm + the A9
        // (TEST eAX,imm32) arm. A 16-bit (66-prefixed) accumulator op carries the
        // 0x66 prefix as b0, so it never reaches this arm — it stays on the slow
        // FSM. ADC(op2)/SBB(op3) = PU (U-only-pairable); CMP(op7) writes no reg.
        8'b00??_?101: begin
          d.simple=1'b1; d.len=def16?4'd3:4'd5; d.alu_op={2'b00,b0[5:3]}; d.wflags=1'b1;
          d.dst=R_EAX; d.src=R_EAX; d.use_imm=1'b1;
          d.imm=def16?{16'd0,b2,b1}:{b4,b3,b2,b1};   // step D: 16-bit immediate is b2:b1
          d.wreg=(b0[5:3]!=3'b111);
          d.reads = _onehot(R_EAX);
          d.writes = d.wreg ? _onehot(R_EAX) : 8'd0;
          d.pairs_first=1'b1;
          d.pairs_second=!(b0[5:3]==3'b010 || b0[5:3]==3'b011);
        end
        // ---- group1 r/m32, imm8 sign-ext (83 /r ib) --------------------------
        8'h83: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd3; d.alu_op={2'b00,reg_f}; d.wflags=1'b1;
            d.use_imm=1'b1; d.imm={{24{b2[7]}},b2}; d.dst=rm; d.src=rm;
            d.wreg=(reg_f!=3'b111);
            d.reads = _onehot(rm);
            d.writes = d.wreg ? _onehot(rm) : 8'd0;
            // imm-only (no displacement) so disp_imm stays 0 -> pairs.
            // /2=ADC, /3=SBB are PU (U-only-pairable); never fill V (see above).
            d.pairs_first=1'b1;
            d.pairs_second=!(reg_f==3'b010 || reg_f==3'b011);
          end else if (!def16 && reg_f==3'b111 && rm!=3'b100 &&
                       !(mod==2'b00 && rm==3'b101)) begin
            // CMP r/m32,imm8.  This is a checked READ, never an RMW write:
            // mem_rdata becomes ALU operand A and the sign-extended immediate
            // is operand B.  Retain only encodings that fit the six-byte fetch
            // window (base, base+disp8); the disp32 form remains slow.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_lhs=1'b1; d.len=4'd3;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.use_imm=1'b1;
                d.imm={{24{b2[7]}},b2}; d.base=rm; d.mem_base_en=1'b1;
                d.mem_ss=(rm==3'b101); d.reads=_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b0;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_lhs=1'b1; d.len=4'd4;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.use_imm=1'b1;
                d.imm={{24{b3[7]}},b3}; d.base=rm; d.mem_base_en=1'b1;
                d.mem_ss=(rm==3'b101); d.mem_disp={{24{b2[7]}},b2};
                d.reads=_onehot(rm); d.addr_mask=_onehot(rm);
                // P5 never pairs an instruction carrying both a displacement
                // and an immediate.  This is metadata for issue_uv only: the
                // packet/ALU semantics above are unchanged.
                d.disp_imm=1'b1;
                d.pairs_first=1'b1; d.pairs_second=1'b0;
              end
              default: ;
            endcase
          end else if (!def16 && reg_f==3'b111 && rm==3'b100 &&
                       !(mod==2'b00 && b2[2:0]==3'b101)) begin
            // Concrete-base SIB versions of the same read-only CMP.  ESP and
            // EBP bases select SS; index=ESP means "no index" architecturally.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_lhs=1'b1; d.len=4'd4;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.use_imm=1'b1;
                d.imm={{24{b3[7]}},b3}; d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.reads=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b0;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_lhs=1'b1; d.len=4'd5;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.use_imm=1'b1;
                d.imm={{24{b4[7]}},b4}; d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.mem_disp={{24{b3[7]}},b3};
                d.reads=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                // Same AP-500 displacement+immediate restriction as the
                // non-SIB mod=01 form above.
                d.disp_imm=1'b1;
                d.pairs_first=1'b1; d.pairs_second=1'b0;
              end
              default: ;
            endcase
          end
        end
        // ---- group1 r/m32, imm32 (81 /r id), reg form — fast-path batch 2 -----
        // The imm32 sibling of the 83 arm above (imm = b2..b5, len 6). Reg form
        // only (mod11, no memory). ALU op = reg_f; ADC/SBB=PU; CMP writes no reg.
        8'h81: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=def16?4'd4:4'd6; d.alu_op={2'b00,reg_f}; d.wflags=1'b1;
            d.use_imm=1'b1;
            d.imm=def16?{16'd0,b3,b2}:{b5,b4,b3,b2};  // step D: 16-bit immediate is b3:b2
            d.dst=rm; d.src=rm;
            d.wreg=(reg_f!=3'b111);
            d.reads = _onehot(rm);
            d.writes = d.wreg ? _onehot(rm) : 8'd0;
            d.pairs_first=1'b1;
            d.pairs_second=!(reg_f==3'b010 || reg_f==3'b011);
          end
        end
        // ---- MOV r/m32, imm32 (C7 /0 id), reg form — fast-path batch 2 --------
        // The ModRM sibling of B8+r. Only /0 (reg_f==0) is MOV (other /r are
        // group11/UD — left to the slow FSM). Reg form only; no flags; imm=b2..b5.
        8'hC7: begin
          if (mod==2'b11 && reg_f==3'b000) begin
            d.simple=1'b1; d.len=def16?4'd4:4'd6; d.alu_op=ALU_MOV;
            d.use_imm=1'b1;
            d.imm=def16?{16'd0,b3,b2}:{b5,b4,b3,b2};  // step D: 16-bit immediate is b3:b2
            d.dst=rm; d.wreg=1'b1;
            d.writes=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
        // ---- INC/DEC r32 (40+r / 48+r) ---------------------------------------
        8'b0100_????: begin
          d.simple=1'b1; d.len=4'd1; d.wflags=1'b1; d.dst=b0[2:0]; d.src=b0[2:0];
          d.alu_op = b0[3] ? ALU_DEC : ALU_INC; d.wreg=1'b1;
          d.reads=_onehot(b0[2:0]); d.writes=_onehot(b0[2:0]);
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
        // ---- PUSH/POP r32 (50+r / 58+r) -------------------------------------
        // These are implicit SS:ESP accesses, not ModR/M memory operations.
        // Keep the first landing deliberately U-only: a POP plus a V-register
        // write has three architectural write destinations (POP dst, ESP, V
        // dst), while the existing AGI history has two entries.  The actual
        // memory transaction still goes through S_PIPE's packet/fragment path;
        // this descriptor only supplies the stack-specific EA and final commit.
        // Operand-size prefixes never reach this decoder, but a 16-bit default
        // code segment can.  Leave that form on the mature slow FSM.
        8'b0101_0???: begin
          if (!def16) begin
            d.simple=1'b1; d.len=4'd1; d.is_mem=1'b1; d.is_store=1'b1;
            d.is_stack=1'b1; d.mem_ss=1'b1; d.src=b0[2:0];
            d.reads=_onehot(b0[2:0])|_onehot(R_ESP);
            d.writes=_onehot(R_ESP); d.addr_mask=_onehot(R_ESP);
            d.pairs_first=1'b0; d.pairs_second=1'b0;
          end
        end
        8'b0101_1???: begin
          if (!def16) begin
            d.simple=1'b1; d.len=4'd1; d.is_mem=1'b1; d.is_load=1'b1;
            d.is_stack=1'b1; d.mem_ss=1'b1; d.dst=b0[2:0]; d.wreg=1'b1;
            d.reads=_onehot(R_ESP);
            d.writes=_onehot(b0[2:0])|_onehot(R_ESP);
            d.addr_mask=_onehot(R_ESP);
            d.pairs_first=1'b0; d.pairs_second=1'b0;
          end
        end
        // ---- MOV r/m32, r32 (89 /r): reg move or checked DS store ------------
        8'h88, 8'h89: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_MOV; d.dst=rm; d.src=reg_f;
            d.wreg=1'b1; d.reads=_onehot(reg_f); d.writes=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && mod==2'b00 && rm==3'b101) begin
            // 32-bit ModR/M disp32 is a literal DS address, never EBP. The
            // fast store is deliberately a plain full-dword MOV only; stack,
            // prefixed, 16-bit, immediate and RMW writes stay on the slow FSM.
            d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd6;
            d.src=reg_f; d.mem_disp={b5,b4,b3,b2}; d.reads=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && rm!=3'b100 && !(mod==2'b00 && rm==3'b101)) begin
            // Base{+disp8|+disp32}: EBP's mod01/mod10 forms default to SS;
            // all other retained bases default to DS. The base is an address
            // input as well as an architectural read: both masks are explicit
            // so the AGI and U/V dependency rules see the same register set.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd2;
                d.src=reg_f; d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd3;
                d.src=reg_f; d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={{24{b2[7]}},b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b10: begin
                d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd6;
                d.src=reg_f; d.base=rm; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={b5,b4,b3,b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end else if (!def16 && rm==3'b100 && !(mod==2'b00 && b2[2:0]==3'b101)) begin
            // SIB with a concrete base. ESP and EBP select SS; all other bases
            // select DS. Retain only no-disp and disp8 forms: a SIB+disp32 is
            // seven bytes and cannot be decoded safely from the six-byte window.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd3;
                d.src=reg_f; d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1; d.len=4'd4;
                d.src=reg_f; d.base=b2[2:0]; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.mem_disp={{24{b3[7]}},b3};
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end
        end
        // ---- MOV r32, r/m32 (8B /r): reg form = reg move; checked memory load
        8'h8A, 8'h8B: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_MOV; d.dst=reg_f; d.src=rm;
            d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && rm!=3'b100 && !(mod==2'b00 && rm==3'b101)) begin
            // MOV r32,[base{+disp8|+disp32}]. EBP's mod01/mod10 forms use SS;
            // the remaining retained bases use DS. mod00/rm=101 (literal DS
            // disp32) is handled below. The segment choice stays decoded with
            // the address so the AGU, bus and paging paths cannot disagree.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_load=1'b1; d.len=4'd2; d.dst=reg_f; d.base=rm;
                d.is_mem=1'b1; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_load=1'b1; d.len=4'd3; d.dst=reg_f; d.base=rm;
                d.is_mem=1'b1; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={{24{b2[7]}},b2};
                d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b10: begin
                d.simple=1'b1; d.is_load=1'b1; d.len=4'd6; d.dst=reg_f; d.base=rm;
                d.is_mem=1'b1; d.mem_base_en=1'b1; d.mem_ss=(rm==3'b101);
                d.mem_disp={b5,b4,b3,b2};
                d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end else if (!def16 && mod==2'b00 && rm==3'b101) begin
            // MOV r32,[disp32].  In 32-bit ModR/M addressing this is a literal
            // DS offset -- NOT EBP.  It is common in Quake's global-state loops;
            // record the no-base fact explicitly so the shared AGU cannot add a
            // coincidental GPR value.  Prefixes/16-bit addressing stay slow.
            d.simple=1'b1; d.is_load=1'b1; d.is_mem=1'b1; d.len=4'd6;
            d.dst=reg_f; d.mem_disp={b5,b4,b3,b2}; d.wreg=1'b1;
            d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && rm==3'b100 && !(mod==2'b00 && b2[2:0]==3'b101)) begin
            // MOV r32,[base+index*scale{+disp8}]. b2 is the SIB byte here.
            // ESP/EBP bases select SS; mod00/base=EBP is the no-base disp32
            // form and remains slow. The index never selects a segment, and
            // index=ESP means no index by x86 definition. Do NOT add mod10:
            // SIB+disp32 is seven bytes, beyond the six-byte fast window.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_load=1'b1; d.len=4'd3; d.dst=reg_f; d.base=b2[2:0];
                d.is_mem=1'b1; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.wreg=1'b1;
                d.reads=_onehot(b2[2:0]) | ((b2[5:3]!=3'b100) ? _onehot(b2[5:3]) : 8'd0);
                d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(b2[2:0]) | ((b2[5:3]!=3'b100) ? _onehot(b2[5:3]) : 8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_load=1'b1; d.len=4'd4; d.dst=reg_f; d.base=b2[2:0];
                d.is_mem=1'b1; d.mem_base_en=1'b1;
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.mem_disp={{24{b3[7]}},b3};
                d.wreg=1'b1;
                d.reads=_onehot(b2[2:0]) | ((b2[5:3]!=3'b100) ? _onehot(b2[5:3]) : 8'd0);
                d.writes=_onehot(reg_f);
                d.addr_mask=_onehot(b2[2:0]) | ((b2[5:3]!=3'b100) ? _onehot(b2[5:3]) : 8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end
        end
        // ---- CMP r32,r/m32 and CMP r/m32,r32: checked DS memory operands ----
        // These forms have no architectural writeback, so they can reuse the
        // existing U-side read handshake without introducing a store buffer or a
        // speculative write.  The U ALU receives mem_rdata on the appropriate
        // side and commits only EFLAGS. Keep prefixes, 16-bit forms and SIB
        // no-base forms on the slow FSM; the decoded SS-default base forms
        // share the same translated read contract as DS.
        8'h3B, 8'h39: begin
          // The broad register-only ALU arms above deliberately exclude CMP so
          // these memory forms cannot overlap a casez item. Preserve the exact
          // original register behaviour here before considering memory.
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_CMP; d.wflags=1'b1;
            d.dst=(b0==8'h3B) ? reg_f : rm;
            d.src=(b0==8'h3B) ? rm : reg_f;
            d.reads=_onehot(reg_f)|_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && mod==2'b00 && rm==3'b101) begin
            d.simple=1'b1; d.is_mem=1'b1; d.len=4'd6; d.alu_op=ALU_CMP; d.wflags=1'b1;
            d.dst=reg_f; d.src=reg_f; d.mem_lhs=(b0==8'h39);
            d.mem_disp={b5,b4,b3,b2}; d.reads=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && rm!=3'b100 && !(mod==2'b00 && rm==3'b101)) begin
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_base_en=1'b1; d.len=4'd2;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.dst=reg_f; d.src=reg_f;
                d.mem_lhs=(b0==8'h39); d.base=rm; d.mem_ss=(rm==3'b101);
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_base_en=1'b1; d.len=4'd3;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.dst=reg_f; d.src=reg_f;
                d.mem_lhs=(b0==8'h39); d.base=rm; d.mem_ss=(rm==3'b101); d.mem_disp={{24{b2[7]}},b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b10: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_base_en=1'b1; d.len=4'd6;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.dst=reg_f; d.src=reg_f;
                d.mem_lhs=(b0==8'h39); d.base=rm; d.mem_ss=(rm==3'b101); d.mem_disp={b5,b4,b3,b2};
                d.reads=_onehot(reg_f)|_onehot(rm); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end else if (!def16 && rm==3'b100 && !(mod==2'b00 && b2[2:0]==3'b101)) begin
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_base_en=1'b1; d.len=4'd3;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.dst=reg_f; d.src=reg_f;
                d.mem_lhs=(b0==8'h39); d.base=b2[2:0];
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101);
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_mem=1'b1; d.mem_base_en=1'b1; d.len=4'd4;
                d.alu_op=ALU_CMP; d.wflags=1'b1; d.dst=reg_f; d.src=reg_f;
                d.mem_lhs=(b0==8'h39); d.base=b2[2:0];
                d.mem_ss=(b2[2:0]==3'b100)||(b2[2:0]==3'b101); d.mem_disp={{24{b3[7]}},b3};
                d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
                d.reads=_onehot(reg_f)|_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end
        end
        // ---- LEA r32, m (8D /r): checked fast-AGU forms ----------------------
        8'h8D: begin
          if (!def16 && mod==2'b00 && rm==3'b101) begin
            // LEA r32,[disp32] is an offset literal, never an EBP read.  It
            // exactly fills the six-byte fetch window and has no segment or
            // translation side effect; it shares the fast AGU only as an adder.
            d.simple=1'b1; d.is_lea=1'b1; d.len=4'd6; d.dst=reg_f;
            d.mem_disp={b5,b4,b3,b2}; d.wreg=1'b1; d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (!def16 && rm!=3'b100 && !(mod==2'b00 && rm==3'b101)) begin
            // Non-SIB base{+disp8|+disp32}.  All of these encodings fit the
            // fetch window; LEA ignores the default segment, but addr_mask
            // still exposes the address input to the AGI/dependency logic.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_lea=1'b1; d.len=4'd2; d.dst=reg_f; d.base=rm;
                d.mem_base_en=1'b1; d.wreg=1'b1; d.reads=_onehot(rm);
                d.writes=_onehot(reg_f); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_lea=1'b1; d.len=4'd3; d.dst=reg_f; d.base=rm;
                d.mem_base_en=1'b1; d.mem_disp={{24{b2[7]}},b2}; d.wreg=1'b1;
                d.reads=_onehot(rm); d.writes=_onehot(reg_f); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b10: begin
                d.simple=1'b1; d.is_lea=1'b1; d.len=4'd6; d.dst=reg_f; d.base=rm;
                d.mem_base_en=1'b1; d.mem_disp={b5,b4,b3,b2}; d.wreg=1'b1;
                d.reads=_onehot(rm); d.writes=_onehot(reg_f); d.addr_mask=_onehot(rm);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end else if (!def16 && rm==3'b100 && !(mod==2'b00 && b2[2:0]==3'b101)) begin
            // Concrete-base SIB LEAs, with no displacement or disp8.  The
            // disp32 SIB forms are seven bytes and remain on the slow decoder.
            unique case (mod)
              2'b00: begin
                d.simple=1'b1; d.is_lea=1'b1; d.len=4'd3; d.dst=reg_f; d.base=b2[2:0];
                d.mem_base_en=1'b1; d.mem_index=b2[5:3]; d.mem_scale=b2[7:6];
                d.mem_index_en=(b2[5:3]!=3'b100); d.wreg=1'b1;
                d.reads=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.writes=_onehot(reg_f); d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              2'b01: begin
                d.simple=1'b1; d.is_lea=1'b1; d.len=4'd4; d.dst=reg_f; d.base=b2[2:0];
                d.mem_base_en=1'b1; d.mem_index=b2[5:3]; d.mem_scale=b2[7:6];
                d.mem_index_en=(b2[5:3]!=3'b100); d.mem_disp={{24{b3[7]}},b3}; d.wreg=1'b1;
                d.reads=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.writes=_onehot(reg_f); d.addr_mask=_onehot(b2[2:0])|((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
                d.pairs_first=1'b1; d.pairs_second=1'b1;
              end
              default: ;
            endcase
          end
        end
        // ---- shift by imm8 (C1 /4,/5,/6,/7 ib), reg form ---------------------
        // SHL/SHR/SAL/SAR are fast-pathed. Optional 32-bit register ROR /1
        // reuses the same shifter but needs rotate-specific CF/OF preservation.
        // The other rotates remain on the slow architectural path.
        8'hC1: begin
          if (mod==2'b11 && (reg_f[2]
`ifdef VEN_FAST_ROR_IMM
                              || (!def16 && reg_f==3'd1)
`endif
                             )) begin
            d.simple=1'b1; d.is_shift=1'b1; d.len=4'd3; d.wflags=1'b1;
            d.shrot=reg_f; d.shimm=b2[4:0]; d.dst=rm; d.wreg=1'b1;
            d.reads=_onehot(rm); d.writes=_onehot(rm);
            // shift-by-imm = U-only pairable (PU): may lead a pair, cannot fill V.
            d.pairs_first=1'b1; d.pairs_second=1'b0;
          end
        end
        // ---- shift by 1 (D1 /4,/5,/6,/7), reg form — fast-path batch 3 --------
        // The implicit-count-1 sibling of C1: SHL/SHR/SAL/SAR r/m32, 1 (the x+x /
        // halve idiom). Same datapath with shimm fixed at 1, no imm byte (len 2),
        // reg form only; rotates (/0..3) keep the slow path. PU like C1. (OF for a
        // 1-bit shift is DEFINED and emerges correctly from the shm1^result rule;
        // the comparator masks it for shl/shr/sar regardless, so it cannot misgate.)
        8'hD1: begin
          if (mod==2'b11 && reg_f[2]) begin   // reg_f in 4..7
            d.simple=1'b1; d.is_shift=1'b1; d.len=4'd2; d.wflags=1'b1;
            d.shrot=reg_f; d.shimm=5'd1; d.dst=rm; d.wreg=1'b1;
            d.reads=_onehot(rm); d.writes=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b0;
          end
        end
        // ---- shift by CL (D3 /4,/5,/6,/7), register form --------------------
        // The variable-count sibling of D1/C1.  P5 classifies CL shifts as NP:
        // they execute in one U-pipe cycle but cannot pair.  Keep byte/word and
        // memory destinations on the slow FSM; the 32-bit register form reuses
        // the existing shared shifter with an explicit live ECX dependency.
        8'hD3: begin
          if (!def16 && mod==2'b11 && reg_f[2]) begin
            d.simple=1'b1; d.is_shift=1'b1; d.shift_cl=1'b1; d.len=4'd2; d.wflags=1'b1;
            d.shrot=reg_f; d.dst=rm; d.src=R_ECX; d.wreg=1'b1;
            d.reads=_onehot(rm)|_onehot(R_ECX); d.writes=_onehot(rm);
            d.pairs_first=1'b0; d.pairs_second=1'b0;
          end
        end
        // ---- TEST eAX, imm32 (A9) --------------------------------------------
        8'hA9: begin
          d.simple=1'b1; d.len=def16?4'd3:4'd5; d.alu_op=ALU_TEST; d.wflags=1'b1;
          d.dst=R_EAX; d.use_imm=1'b1;
          d.imm=def16?{16'd0,b2,b1}:{b4,b3,b2,b1};   // step D: 16-bit immediate is b2:b1
          d.reads=_onehot(R_EAX);
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
        // ---- TEST r/m32, r32 (85 /r), reg form — fast-path batch 4 -----------
        // Reuses the ALU_TEST datapath (like A9): AND-for-flags only, writes no
        // reg. UV-pairable. (The byte form 84 is left to the slow FSM — byte-width
        // flags are not in the 32-bit fast-path datapath.)
        8'h85: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_TEST; d.wflags=1'b1;
            d.dst=rm; d.src=reg_f;
            d.reads=_onehot(rm)|_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
        // ---- NOP (90) --------------------------------------------------------
        8'h90: begin
          d.simple=1'b1; d.is_nop=1'b1; d.len=4'd1;
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
`ifdef VEN_FAST_XCHG_R
        8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97: begin
          // P54 Appendix F: XCHG eAX,r is NP, two clocks. The two old
          // register values are captured by the single ordered U commit;
          // no flags or memory transaction is involved.
          d.simple=1'b1; d.is_xchg_r=1'b1; d.len=4'd1;
          d.dst=R_EAX; d.src=b0[2:0]; d.wreg=1'b1;
          d.reads=_onehot(R_EAX)|_onehot(b0[2:0]);
          d.writes=d.reads;
        end
`endif
        // ---- MOV EAX,moffs32 (A1): checked absolute DS load -----------------
        // A1 is the compact five-byte global-load form emitted heavily by
        // non-PIC 32-bit code.  It is semantically the same read contract as
        // 8B /r disp32: a literal DS offset, dword width, no GPR address input,
        // and a real mem_ack/fragment-engine wait before the EAX writeback.
        // A0 (byte), A2 (byte store), and operand-size-prefixed A1 stay on
        // the slow FSM because they need width-specific machinery.  A3 is a
        // separately gated, real packet-store extension immediately below.
        8'hA1: begin
          if (!def16) begin
            d.simple=1'b1; d.is_load=1'b1; d.is_mem=1'b1; d.len=4'd5;
            d.dst=R_EAX; d.mem_disp={b4,b3,b2,b1}; d.wreg=1'b1;
            d.writes=_onehot(R_EAX);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
`ifdef VEN_FAST_MOFFS_STORE
        // MOV moffs32,EAX (A3): checked absolute DS store.  Unlike the
        // withdrawn cycle-model shortcut below, this is a real S_PIPE memory
        // packet: it drives the write handshake and cannot retire before the
        // final acknowledgement.  Keep A2 (byte width), 16-bit-default, and
        // prefixed variants on the slow FSM.  is_moffs is architecturally
        // significant because the Erratum-59 pairing model consumes it.
        8'hA3: begin
          if (!def16) begin
            d.simple=1'b1; d.is_mem=1'b1; d.is_store=1'b1;
            d.is_moffs=1'b1; d.len=4'd5; d.src=R_EAX;
            d.mem_disp={b4,b3,b2,b1}; d.reads=_onehot(R_EAX);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
`endif
        // ---- M6 Erratum 59: MOV moffs8,AL (A2) / MOV moffs,eAX (A3) ----------
        // A2 remains on the proven width-aware slow store path.  The historical
        // A2/A3 cycle-only fast arm is intentionally not restored: it modeled
        // only retirement/pairing and allowed a moffs store to retire without a
        // memory write (REVIEW_Jul29 H-02).  The optional A3 arm above is the
        // required replacement shape: a full-dword S_PIPE packet with a real
        // final-acknowledgement commit.  Its is_moffs bit lets core.sv apply the
        // documented false EAX dependency to the following instruction when
        // ERR_MOFFS is enabled.  Do not extend A2 by copying A3; it needs byte
        // strobes and its own functional/fault matrix.
        // ---- Jcc rel8 (70..7F) -----------------------------------------------
        8'b0111_????: begin
          d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b1; d.len=4'd2;
          d.cc=b0[3:0]; d.br_taken=cond_true(b0[3:0],flags_in); d.rel={{24{b1[7]}},b1};
          // simple near branch = V-only pairable (can fill V, cannot lead a pair)
          d.pairs_first=1'b0; d.pairs_second=1'b1;
        end
        // ---- JMP rel8 (EB) / Jcc rel32 (0F 8x) handled minimally -------------
        8'hEB: begin
          d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b0; d.len=4'd2;
          d.br_taken=1'b1; d.rel={{24{b1[7]}},b1};
          // M5 finding [med]: an unconditional short JMP (EB) is V-only-pairable in
          // the oracle (verif/qemu-plugins/p5trace.c:271-273: JMP -> pclass=PV,
          // pairs_second=true) — exactly like a Jcc rel8. It can FILL the V slot of
          // a pair (e.g. `<UV op>; jmp`) but cannot LEAD a pair. Matching this pairs
          // the `<mov>; jmp` groups the assembler's p2align filler emits (mb_imiss).
          d.pairs_first=1'b0; d.pairs_second=1'b1;
        end
        // ---- JMP rel32 (E9) — fast-path batch 4 ------------------------------
        // The near (32-bit displacement) sibling of EB; same branch datapath with
        // rel = b4..b1 (len 5). PV (V-only-pairable, like EB).
        8'hE9: begin
          d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b0; d.len=def16?4'd3:4'd5;
          d.br_taken=1'b1; d.rel=def16?{{16{b2[7]}},b2,b1}:{b4,b3,b2,b1};
          d.pairs_first=1'b0; d.pairs_second=1'b1;
        end
        // ---- Jcc rel32 (0F 8x) — fast-path batch 4 ---------------------------
        // The near (32-bit displacement) sibling of the 7x Jcc rel8 arm. b0=0x0F,
        // b1 in 80..8F selects the condition (cc=b1[3:0]); rel = b5..b2 (len 6).
        // PV like 7x. Only the 8x sub-range is fast-pathed; every other 0F two-byte
        // op leaves simple=0 and falls to the slow FSM.
        8'h0F: begin
          if (b1[7:4]==4'h8) begin
            d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b1; d.len=def16?4'd4:4'd6;
            d.cc=b1[3:0]; d.br_taken=cond_true(b1[3:0],flags_in); d.rel=def16?{{16{b3[7]}},b3,b2}:{b5,b4,b3,b2};
            d.pairs_first=1'b0; d.pairs_second=1'b1;
          end
`ifdef VEN_FAST_MEM_EXT
          else if (!def16 && (b1==8'hB6 || b1==8'hB7 || b1==8'hBE || b1==8'hBF) &&
                   b2[7:6]!=2'b11 && b2[5:3]!=3'd4 &&
                   // SIB+disp32 is eight bytes with the two-byte opcode.
                   !(b2[2:0]==3'd4 && (b2[7:6]==2'b10 ||
                     (b2[7:6]==2'b00 && b3[2:0]==3'd5)))) begin
            d.simple=1'b1; d.is_load=1'b1; d.is_mem=1'b1;
            d.wreg=1'b1; d.wflags=1'b0; d.dst=b2[5:3];
            d.alu_op=FP_LOAD_ZX8 + {3'd0,b1[3],b1[0]};
            // Pinned P5 model: NP, occ2/lat2. Never a U/V pair participant.
            d.pairs_first=1'b0; d.pairs_second=1'b0;
            d.len=4'd3;
            if (b2[2:0]==3'd4) begin
              d.len=4'd4; d.base=b3[2:0]; d.mem_base_en=1'b1;
              d.mem_ss=(b3[2:0]==3'd4 || b3[2:0]==3'd5);
              d.mem_index=b3[5:3]; d.mem_scale=b3[7:6];
              d.mem_index_en=(b3[5:3]!=3'd4);
              if (b2[7:6]==2'b01) begin
                d.len=4'd5; d.mem_disp={{24{b4[7]}},b4};
              end
            end else begin
              d.base=b2[2:0];
              d.mem_base_en=!(b2[7:6]==2'b00 && b2[2:0]==3'd5);
              d.mem_ss=d.mem_base_en && (b2[2:0]==3'd5);
              if (b2[7:6]==2'b01) begin
                d.len=4'd4; d.mem_disp={{24{b3[7]}},b3};
              end else if (b2[7:6]==2'b10 || !d.mem_base_en) begin
                d.len=4'd7; d.mem_disp={b6,b5,b4,b3};
              end
            end
            d.addr_mask=(d.mem_base_en ? _onehot(d.base) : 8'd0) |
                        (d.mem_index_en ? _onehot(d.mem_index) : 8'd0);
            d.reads=d.addr_mask; d.writes=_onehot(d.dst);
          end
`endif
        end
        // ---- M5: x87 register-form FP whitelist (cycle-mode only) ------------
        // These are recognised by the fast path so the FP latency/throughput
        // CYCLE model is emergent (p5model fp_role scoreboard). simple stays 0
        // (so the fast path does NOT treat them as integer ALU ops) but is_fp
        // marks the FP commit path. FP ops never pair (NP in p5model): they hold
        // the U pipe alone, so pairs_first/second stay 0. Gated on cycle_mode so
        // func runs keep FP on the proven slow FSM (zero functional risk).
        8'b1101_1???: if (cycle_mode) begin
          // register form only (mod==11); memory-operand FP stays slow-path.
          if (b1[7:6]==2'b11) begin
            unique case (b0)
              8'hD9: begin
                unique casez (b1)
                  8'b1100_0???: begin   // D9 C0+i  FLD ST(i)  (push copy)
                    d.is_fp=1'b1; d.fp_kind=FK_FLDSTI; d.len=4'd2;
                    d.fp_sti=b1[2:0]; d.fp_role=3'd1; d.fp_lat=7'd1; d.fp_occ=7'd1;
                  end
                  8'b1100_1???: begin   // D9 C8+i  FXCH ST(i)
                    d.is_fp=1'b1; d.fp_kind=FK_FXCH; d.len=4'd2;
                    d.fp_sti=b1[2:0]; d.fp_role=3'd0; d.fp_lat=7'd1; d.fp_occ=7'd1;
`ifdef VEN_FXCH_FREE
                    // GAP2: the P5 FXCH is a free stack rename — it folds into the
                    // preceding push's commit clock (occ 0). Marked here; the spine's
                    // FP push-commit arm absorbs it. (A lone/unfoldable FXCH still
                    // costs its own clock via the normal commit, matching occ=1.)
                    d.is_fxch_free=1'b1; d.fp_occ=7'd0;
`endif
                  end
                  8'hE8,8'hE9,8'hEA,8'hEB,8'hEC,8'hED,8'hEE: begin // FLD const (E8=FLD1..)
                    d.is_fp=1'b1; d.fp_kind=FK_FLDC; d.len=4'd2;
                    d.fp_sti=(b1==8'hE8)?3'd0:(b1==8'hE9)?3'd1:(b1==8'hEA)?3'd2:
                             (b1==8'hEB)?3'd3:(b1==8'hEC)?3'd4:(b1==8'hED)?3'd5:3'd6;
                    // FLD-const is occ=2/lat=2 in the oracle (verif/qemu-plugins/
                    // p5trace.c:307-309), NOT the lat-1 of FLD ST(i)/FLD mem.
                    d.fp_role=3'd1; d.fp_lat=7'd2; d.fp_occ=7'd2;
                  end
                  default: ;  // other D9 reg-form ops stay slow-path
                endcase
              end
              8'hD8: begin            // D8 C0+i.. : ST0 op= ST(i)  (add/mul/sub/div)
                unique case (b1[5:3])
                  3'd0,3'd1,3'd4,3'd5,3'd6,3'd7: begin
                    d.is_fp=1'b1; d.fp_kind=FK_ARITH; d.len=4'd2;
                    d.fp_aluop=b1[5:3]; d.fp_sti=b1[2:0]; d.fp_role=3'd3;
                    // Match the oracle classify() (verif/qemu-plugins/p5trace.c:
                    // 285-297): fadd/fsub LAT 3 / OCC 1; fmul LAT 3 / OCC 2; fdiv/
                    // fdivr LAT 39 / OCC 39 (extended PC). LATENCY governs a
                    // dependent consumer's stall (fp_ready); OCCUPANCY governs how
                    // long this op holds the in-order pipe (delays the NEXT insn,
                    // even an independent integer op) — the two are distinct.
                    // group: 0=FADD 1=FMUL 4=FSUB 5=FSUBR 6=FDIV 7=FDIVR.
                    d.fp_lat = (b1[5:3]==3'd6||b1[5:3]==3'd7) ? 7'd39 : 7'd3;
                    d.fp_occ = (b1[5:3]==3'd6||b1[5:3]==3'd7) ? 7'd39 :
                               (b1[5:3]==3'd1)                ? 7'd2  : 7'd1;
`ifdef VEN_SRT_ITER
                    // div/divr take the slow FSM (S_FEXEC -> iterative SRT engine);
                    // drop the fast-path FP classification so they fall through.
                    if (b1[5:3]==3'd6 || b1[5:3]==3'd7) d.is_fp=1'b0;
`endif
                  end
                  default: ;  // FCOM/FCOMP reg-form stay slow-path
                endcase
              end
`ifdef VEN_FP_SHARED
`ifdef VEN_FP_SHARED_DIRECT
              // The shared-FP handoff already owns the indexed destination and
              // write-before-pop ordering for FX_AR_STI_ST0.  Admit only the
              // registered ALU classes here: divide/divr deliberately retain
              // the proven S_FETCH/S_DECODE -> shared-SRT route.  This whole
              // arm is shared-direct-only so legacy fpu_writeback never sees
              // the new FK_ARITH_STI{,_POP} encodings.
              8'hDC: begin            // DC C0+i.. : ST(i) op= ST0
                unique case (b1[5:3])
                  3'd0,3'd1,3'd4,3'd5: begin
                    d.is_fp=1'b1; d.fp_kind=FK_ARITH_STI; d.len=4'd2;
                    // For ST(i)-destination SUB/SUBR, the architectural
                    // opcode senses are reversed versus ST0-destination D8.
                    // f_arith receives {a=ST(i),b=ST0}, hence invert op[0]
                    // exactly as the slow decoder does for DC/DE.
                    d.fp_aluop=(b1[5:3] == 3'd4 || b1[5:3] == 3'd5)
                             ? {b1[5:4],~b1[3]} : b1[5:3];
                    d.fp_sti=b1[2:0]; d.fp_role=3'd3; d.fp_lat=7'd3;
                    d.fp_occ=(b1[5:3] == 3'd1) ? 7'd2 : 7'd1;
                  end
                  default: ; // FCOM/FCOMP and FDIV/FDIVR stay slow-path
                endcase
              end
              8'hDE: begin            // DE C0+i.. : ST(i) op= ST0, then pop
                unique case (b1[5:3])
                  3'd0,3'd1,3'd4,3'd5: begin
                    d.is_fp=1'b1; d.fp_kind=FK_ARITH_STI_POP; d.len=4'd2;
                    // Same operand-sense correction as DC above.  DE D9 is
                    // FCOMPP (reg=3), and is intentionally left slow.
                    d.fp_aluop=(b1[5:3] == 3'd4 || b1[5:3] == 3'd5)
                             ? {b1[5:4],~b1[3]} : b1[5:3];
                    d.fp_sti=b1[2:0]; d.fp_role=3'd3; d.fp_lat=7'd3;
                    d.fp_occ=(b1[5:3] == 3'd1) ? 7'd2 : 7'd1;
                  end
                  default: ; // FCOMPP, FCOM/FCOMP aliases, and divide remain slow
                endcase
              end
`endif
`endif
              8'hDD: begin
                unique casez (b1)
                  // DD D8 ONLY — FSTP ST(0), i.e. "discard the top", which is a pure
                  // pop. REVIEW_Jul29 H-01: this used to match DD D8+i for ALL i
                  // (8'b1101_1???) and commit as a bare pop, silently dropping the
                  // required ST0->ST(i) copy for i!=0.
                  // First fix attempt performed the indexed write here (fp_we_sti with
                  // a variable index) — correct, but it added a mux to the FAST-path
                  // fpr write and cost ~2.7 ns on an already-marginal core path: the
                  // routed WNS went +0.187 -> -2.565 with the failing endpoints named
                  // as u_fpu_state/fpr_flat[*], fpp_a[*], u_fpu_wb/fpp_valid_reg[*].
                  // So take the review's OTHER option instead: fast-path only i==0 and
                  // let FSTP ST(i!=0) fall to the SLOW decoder, which already
                  // implements the copy-then-pop correctly (decode_stages.sv:1627-1633).
                  // Same correctness, zero timing cost.
                  8'b1101_1000: begin   // DD D8  FSTP ST(0)  (discard + pop)
                    d.is_fp=1'b1; d.fp_kind=FK_FSTP0; d.len=4'd2;
                    d.fp_sti=3'd0; d.fp_role=3'd0; d.fp_lat=7'd1; d.fp_occ=7'd1;
                  end
                  default: ;
                endcase
              end
              default: ;
            endcase
          end
        end
        default: ;
      endcase
`ifdef VEN_FP_SHARED
`ifdef VEN_FP_SHARED_DIRECT
`ifdef VEN_FP_MEM_ADMIT
    // Read-only D8/DC arithmetic. Never expose this descriptor to the legacy
    // FP retirement path, which treats is_fp as an executable register op.
    // No prefixes or 16-bit address grammar are admitted. All required bytes
    // fit the seven-byte input; publication still checks the complete extent.
    if (cycle_mode && !def16 && mod!=2'b11 &&
        (((b0==8'hD8 || b0==8'hDC) && reg_f!=3'd2 && reg_f!=3'd3) || fp_mem_load)) begin
      d.is_fp=1'b1; d.fp_kind=FK_MEM; d.fp_aluop=reg_f;
      d.fp_sti={2'd0,fp_mem_load?fp_mem_wide:b0[2]};
      // FK_MEM-only flavor: 0 arithmetic, 1 floating load, 2 integer load.
      // Legacy register kinds retain their existing scoreboard role encoding.
      d.fp_role=fp_mem_load?(fp_mem_integer?3'd2:3'd1):3'd0;
      // Leave simple/is_mem/read-write flags clear: S_FLOAD alone owns the
      // request, after the packet has been captured and permissions checked.
      d.base=(rm==3'b100)?b2[2:0]:rm;
      d.mem_base_en=!((mod==2'b00) && (d.base==3'b101));
      d.mem_ss=d.mem_base_en && (d.base==3'b100 || d.base==3'b101);
      // Without SIB, b2 may be outside this instruction (and in a different
      // cache line). Even disabled metadata must have a canonical encoding so
      // cached and live descriptors do not depend on unrelated trailing bytes.
      d.mem_index=(rm==3'b100)?b2[5:3]:3'd0;
      d.mem_scale=(rm==3'b100)?b2[7:6]:2'd0;
      d.mem_index_en=(rm==3'b100) && (b2[5:3]!=3'b100);
      d.addr_mask=(d.mem_base_en?_onehot(d.base):8'd0) |
                  (d.mem_index_en?_onehot(d.mem_index):8'd0);
      d.reads=d.addr_mask;
      d.len=(rm==3'b100)?4'd3:4'd2;
      if (mod==2'b01) begin
        d.len=d.len+4'd1;
        d.mem_disp=(rm==3'b100)?{{24{b3[7]}},b3}:{{24{b2[7]}},b2};
      end else if (mod==2'b10 || !d.mem_base_en) begin
        d.len=d.len+4'd4;
        d.mem_disp=(rm==3'b100)?{b6,b5,b4,b3}:{b5,b4,b3,b2};
      end
    end
`endif
`endif
`endif
`ifdef VEN_FAST_MEM_ALU
    // Apply only to memory descriptors actually admitted by the checked arm.
    // Address masks, segment identity and operand ordering remain unchanged.
    if (d.simple && d.is_mem && checked_add_opcode) begin
      d.alu_op = {2'b00,b0[5:3]};
      d.pairs_second = !(b0[5:3]==3'b010 || b0[5:3]==3'b011);
    end
`elsif VEN_FAST_MEM_ADC
    // Address/dependency metadata comes from the same checked ADD packet.
    // The existing U ALU consumes architectural CF after the final memory
    // response; ADC may lead a pair but cannot execute in the V slot.
    if (d.simple && d.is_mem && b0 == 8'h13) begin
      d.alu_op = ALU_ADC;
      d.pairs_second = 1'b0;
    end
`endif
`ifdef VEN_FAST_MEM_MOV7
    // Generic SIB+disp32 MOV forms. Reuse the existing packet/AGU and byte
    // normalization below; no additional memory transaction or bypass path.
    // mod00/base5 is an absent base (DS), not EBP (SS).
    if (!def16 && (b0==8'h88 || b0==8'h89 || b0==8'h8A || b0==8'h8B) &&
        rm==3'b100 && (mod==2'b10 || (mod==2'b00 && b2[2:0]==3'b101))) begin
      d.simple=1'b1; d.len=4'd7; d.alu_op=ALU_MOV;
      d.is_mem=1'b1; d.is_load=b0[1]; d.is_store=!b0[1];
      d.wreg=b0[1]; d.wflags=1'b0;
      d.base=b2[2:0]; d.mem_base_en=(mod==2'b10);
      d.mem_ss=(mod==2'b10) && (b2[2:0]==3'b100 || b2[2:0]==3'b101);
      d.mem_index=b2[5:3]; d.mem_scale=b2[7:6]; d.mem_index_en=(b2[5:3]!=3'b100);
      d.mem_disp={b6,b5,b4,b3};
      d.addr_mask=((mod==2'b10)?_onehot(b2[2:0]):8'd0) |
                  ((b2[5:3]!=3'b100)?_onehot(b2[5:3]):8'd0);
      d.src=reg_f; d.dst=reg_f;
      d.reads=d.addr_mask | (b0[1]?8'd0:_onehot(reg_f));
      d.writes=b0[1]?_onehot(reg_f):8'd0;
      d.pairs_first=1'b1; d.pairs_second=1'b1;
    end
`endif
    // ---- (removed) three 16-bit BISECT scaffolds ---------------------------
    // VEN_D16_MOVONLY / VEN_D16_NOWREG / VEN_D16_NOPAIR used to sit here, each
    // narrowing what `simple` admits in 16-bit mode to binary-search the boot
    // failure. All three premises are REFUTED: the bug was never in the register
    // write, the flag commit, or the pairing decision -- it was C-01, a stale copy
    // of the issue predicate in core_gpr_wb.svh that dropped gpr_we entirely.
    // VEN_D16_NOWREG "worked" only because rejecting register writers removed
    // exactly the instructions whose writes were being discarded, which is what
    // made it look like a writeback defect. Removed rather than left gated off:
    // the comments asserted those hypotheses as live leads and would send the next
    // reader down three dead paths. (DISK_BOOT_STATUS UPDATE 301.)
    // Byte MOV shares the same effective-address decode as word/dword MOV.
    // Remap only DATA operands; address masks/base/index remain full GPRs.
    // Retain w16 for code-address wrapping. Memory forms above still require
    // 32-bit addressing; unsupported prefixes/16-bit memory forms stay slow.
    if (d.simple && (b0 == 8'h88 || b0 == 8'h8A)) begin
      d.w8 = 1'b1;
      if (d.is_store) begin
        d.src = fp_byte_parent(reg_f);
        d.src_hi8 = reg_f[2];
        d.reads = d.addr_mask | _onehot(d.src);
      end else if (d.is_load) begin
        d.dst = fp_byte_parent(reg_f);
        d.dst_hi8 = reg_f[2];
        d.reads = d.addr_mask;
        d.writes = _onehot(d.dst);
      end else begin
        d.dst_hi8 = d.dst[2];
        d.src_hi8 = d.src[2];
        d.dst = fp_byte_parent(d.dst);
        d.src = fp_byte_parent(d.src);
        d.reads = _onehot(d.src);
        d.writes = _onehot(d.dst);
      end
    end
    return d;
    end
  endfunction

  // One-hot of a 3-bit GP index.  ESP must participate in the dependency masks:
  // V reads the pre-issue register file and there is no stack-pointer bypass.
  // issue_uv retains the deliberate ESP-WAW-only pairing exception separately.
  function automatic logic [7:0] _onehot(input logic [2:0] r);
    _onehot = 8'd1 << r;
  endfunction

  // Drive the decoded-uop output combinationally. Bit-identical to the in-line
  // `fp_decode(...)` calls in intcore.sv (the function read cycle_mode from its
  // enclosing module's port; here it reads this module's port — same value).
  always_comb uop = fp_decode(ib0, ib1, ib2, ib3, ib4, ib5, ib6, iflags);

endmodule : decode
