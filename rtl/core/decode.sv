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
// uop struct + length out. b0..b5 are the 6 fast-path decode bytes; flags_in is
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
    input  logic [31:0] iflags,
    input  logic        cycle_mode,
    output fpd_t        uop
);

  // ---- fast-path decoder (moved verbatim from intcore.sv) -------------------
  function automatic fpd_t fp_decode(input logic [7:0] b0, input logic [7:0] b1,
                                     input logic [7:0] b2, input logic [7:0] b3,
                                     input logic [7:0] b4, input logic [7:0] b5,
                                     input logic [31:0] flags_in);
    fpd_t d;
    logic [1:0] mod; logic [2:0] reg_f, rm;
    begin
      d = '{default:'0};
      d.alu_op = ALU_ADD; d.len = 4'd1;
      mod = b1[7:6]; reg_f = b1[5:3]; rm = b1[2:0];
      unique casez (b0)
        // ---- MOV r32, imm32 (B8+r) -------------------------------------------
        8'b1011_1???: begin
          d.simple=1'b1; d.len=4'd5; d.alu_op=ALU_MOV; d.wreg=1'b1; d.use_imm=1'b1;
          d.dst=b0[2:0]; d.imm={b4,b3,b2,b1};
          d.writes={5'd0, _onehot(b0[2:0])}[7:0];
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
        // ---- ALU r/m32, r32 (00/08/.. /r reg form) : add/or/adc/sbb/and/sub/xor
        8'b00??_?001: begin
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
        8'b00??_?011: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op={2'b00,b0[5:3]}; d.wflags=1'b1;
            d.dst=reg_f; d.src=rm; d.wreg=(b0[5:3]!=3'b111);
            d.reads = _onehot(rm) | _onehot(reg_f);
            d.writes = d.wreg ? _onehot(reg_f) : 8'd0;
            // ADC(op2)/SBB(op3) = PU (U-only-pairable); never fill V (see above).
            d.pairs_first=1'b1;
            d.pairs_second=!(b0[5:3]==3'b010 || b0[5:3]==3'b011);
          end
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
          d.simple=1'b1; d.len=4'd5; d.alu_op={2'b00,b0[5:3]}; d.wflags=1'b1;
          d.dst=R_EAX; d.src=R_EAX; d.use_imm=1'b1; d.imm={b4,b3,b2,b1};
          d.wreg=(b0[5:3]!=3'b111);
          d.reads = _onehot(R_EAX);
          d.writes = d.wreg ? _onehot(R_EAX) : 8'd0;
          d.pairs_first=1'b1;
          d.pairs_second=!(b0[5:3]==3'b010 || b0[5:3]==3'b011);
        end
        // ---- group1 r/m32, imm8 sign-ext (83 /r ib), reg form ----------------
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
          end
        end
        // ---- group1 r/m32, imm32 (81 /r id), reg form — fast-path batch 2 -----
        // The imm32 sibling of the 83 arm above (imm = b2..b5, len 6). Reg form
        // only (mod11, no memory). ALU op = reg_f; ADC/SBB=PU; CMP writes no reg.
        8'h81: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd6; d.alu_op={2'b00,reg_f}; d.wflags=1'b1;
            d.use_imm=1'b1; d.imm={b5,b4,b3,b2}; d.dst=rm; d.src=rm;
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
            d.simple=1'b1; d.len=4'd6; d.alu_op=ALU_MOV;
            d.use_imm=1'b1; d.imm={b5,b4,b3,b2}; d.dst=rm; d.wreg=1'b1;
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
        // ---- MOV r/m32, r32 (89 /r reg form) ---------------------------------
        8'h89: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_MOV; d.dst=rm; d.src=reg_f;
            d.wreg=1'b1; d.reads=_onehot(reg_f); d.writes=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
        // ---- MOV r32, r/m32 (8B /r): reg form = reg move; mod00 = reg-base load
        8'h8B: begin
          if (mod==2'b11) begin
            d.simple=1'b1; d.len=4'd2; d.alu_op=ALU_MOV; d.dst=reg_f; d.src=rm;
            d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end else if (mod==2'b00 && rm!=3'b100 && rm!=3'b101) begin
            // MOV r32,(base) : register-indirect load, no SIB/disp.
            d.simple=1'b1; d.is_load=1'b1; d.len=4'd2; d.dst=reg_f; d.base=rm;
            d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
            d.addr_mask=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
        // ---- LEA r32, m (8D /r) : register-indirect form only ----------------
        8'h8D: begin
          if (mod==2'b00 && rm!=3'b100 && rm!=3'b101) begin
            d.simple=1'b1; d.is_lea=1'b1; d.len=4'd2; d.dst=reg_f; d.base=rm;
            d.wreg=1'b1; d.reads=_onehot(rm); d.writes=_onehot(reg_f);
            d.addr_mask=_onehot(rm);
            d.pairs_first=1'b1; d.pairs_second=1'b1;
          end
        end
        // ---- shift by imm8 (C1 /4,/5,/6,/7 ib), reg form ---------------------
        // Only the SHL/SHR/SAL/SAR group is fast-pathed (its flag rules are
        // simple + matched to the slow path); ROL/ROR/RCL/RCR (/0../3) keep
        // their richer OF semantics on the slow path (simple=0 -> fallback).
        8'hC1: begin
          if (mod==2'b11 && reg_f[2]) begin   // reg_f in 4..7
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
        // ---- TEST eAX, imm32 (A9) --------------------------------------------
        8'hA9: begin
          d.simple=1'b1; d.len=4'd5; d.alu_op=ALU_TEST; d.wflags=1'b1;
          d.dst=R_EAX; d.use_imm=1'b1; d.imm={b4,b3,b2,b1};
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
        // ---- M6 Erratum 59: MOV moffs8,AL (A2) / MOV moffs,eAX (A3) ----------
        // The absolute-displacement store short forms. CYCLE-MODE ONLY (func mode
        // keeps moffs on the proven slow FSM; the store value is not traced, so
        // here we model only the retire + pairing behavior). These are UV-pairable
        // per the SDM (d.pairs_first/second=1); is_moffs lets the pairing logic
        // reproduce the documented false-EAX-dependency non-pairing behind the
        // errata flag. The store reads EAX (its data source) -> reads=EAX so a
        // genuine RAW with a prior EAX writer is still honored; the ERRATUM adds a
        // false dep on the FOLLOWING EAX reader (handled in core.sv pairing).
        8'hA2, 8'hA3: if (cycle_mode) begin
          d.simple=1'b1; d.is_moffs=1'b1; d.len=4'd5;
          d.dst=R_EAX; d.src=R_EAX;             // data source = (e)AX
          d.reads=_onehot(R_EAX);               // reads EAX (the stored datum)
          d.writes=8'd0;                        // a store writes no GP register
          d.pairs_first=1'b1; d.pairs_second=1'b1;
        end
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
          d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b0; d.len=4'd5;
          d.br_taken=1'b1; d.rel={b4,b3,b2,b1};
          d.pairs_first=1'b0; d.pairs_second=1'b1;
        end
        // ---- Jcc rel32 (0F 8x) — fast-path batch 4 ---------------------------
        // The near (32-bit displacement) sibling of the 7x Jcc rel8 arm. b0=0x0F,
        // b1 in 80..8F selects the condition (cc=b1[3:0]); rel = b5..b2 (len 6).
        // PV like 7x. Only the 8x sub-range is fast-pathed; every other 0F two-byte
        // op leaves simple=0 and falls to the slow FSM.
        8'h0F: begin
          if (b1[7:4]==4'h8) begin
            d.simple=1'b1; d.is_branch=1'b1; d.br_cond=1'b1; d.len=4'd6;
            d.cc=b1[3:0]; d.br_taken=cond_true(b1[3:0],flags_in); d.rel={b5,b4,b3,b2};
            d.pairs_first=1'b0; d.pairs_second=1'b1;
          end
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
              8'hDD: begin
                unique casez (b1)
                  8'b1101_1???: begin   // DD D8+i  FSTP ST(i)  (pop). FSTP st(0)=discard.
                    d.is_fp=1'b1; d.fp_kind=FK_FSTP0; d.len=4'd2;
                    d.fp_sti=b1[2:0]; d.fp_role=3'd0; d.fp_lat=7'd1; d.fp_occ=7'd1;
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
      return d;
    end
  endfunction

  // one-hot of a 3-bit GP index, ESP (index 4) excluded from dep masks.
  function automatic logic [7:0] _onehot(input logic [2:0] r);
    _onehot = (r==R_ESP) ? 8'd0 : (8'd1 << r);
  endfunction

  // Drive the decoded-uop output combinationally. Bit-identical to the in-line
  // `fp_decode(...)` calls in intcore.sv (the function read cycle_mode from its
  // enclosing module's port; here it reads this module's port — same value).
  always_comb uop = fp_decode(ib0, ib1, ib2, ib3, ib4, ib5, iflags);

endmodule : decode
