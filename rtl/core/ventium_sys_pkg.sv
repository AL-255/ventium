// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/ventium_sys_pkg.sv — SYSTEM-mode pure helpers (R2 modularization,
// docs/rtl-refactor-plan.md): x86 GDT/LDT descriptor field extraction, segment
// type/attribute predicates, the protected-mode descriptor-load fault DECISION
// + its IDT vector, the 32-bit TSS field byte-offset tables (task-switch save/
// read), and the effective-addressing-size ModR/M length helper.
//
// Extracted VERBATIM from core.sv. Every body uses ONLY its own args + literals
// (and, for mfl_e, the mfl() helper from ventium_decode_pkg) — no module state —
// so this is a no-op to the netlist (a pure-function package move). seg_writable/
// seg_readable/seg_load_fault/seg_fault_vec call the desc_* helpers that move
// here with them. sreg_idx() was NOT moved: its body references the module-local
// SG_CS..SG_GS localparams and stays in core.sv.
//
// Imports ventium_decode_pkg::* for mfl() (used by mfl_e in the !a16 path).

package ventium_sys_pkg;

  import ventium_decode_pkg::*;

  // M2S.1 — ModR/M length contribution under EFFECTIVE addressing size. In
  // 32-bit addressing this is exactly the existing mfl(); in 16-bit addressing
  // (real mode w/o 0x67) the ONLY form the gate uses is [disp16] (mod00,rm110) =
  // 1 ModR/M byte + 2 disp = 3 bytes. (No SIB in 16-bit mode.) Other 16-bit
  // forms are unused by the gate and decode as length-2 here, but their handlers
  // also raise d_unknown so the wrong length is never committed.
  function automatic logic [3:0] mfl_e(input logic a16, input logic [1:0] mod,
                                       input logic [2:0] rm, input logic sib,
                                       input logic [2:0] base);
    if (!a16) return mfl(mod, rm, sib, base);
    // 16-bit addressing:
    if (mod==2'b00 && rm==3'b110) return 4'd3;       // [disp16]
    else if (mod==2'b00)          return 4'd1;       // [reg]/[reg+reg]
    else if (mod==2'b01)          return 4'd2;       // +disp8
    else if (mod==2'b10)          return 4'd3;       // +disp16
    else                          return 4'd1;       // reg-direct
  endfunction

  // x86 8-byte GDT/LDT descriptor field extraction (docs/m2s1-segmentation-spec).
  //   base  = desc[63:56]<<24 | desc[39:16]
  //   limit = desc[51:48]<<16 | desc[15:0]; granularity (G=desc[55]) scales by 4K.
  function automatic logic [31:0] desc_base(input logic [63:0] d);
    desc_base = {d[63:56], d[39:16]};
  endfunction
  function automatic logic [31:0] desc_limit(input logic [63:0] d);
    logic [19:0] lim20;
    begin
      lim20 = {d[51:48], d[15:0]};
      desc_limit = d[55] ? {lim20, 12'hFFF} : {12'd0, lim20};
    end
  endfunction
  // The descriptor access byte = d[47:40] = P|DPL[1:0]|S|type[3:0].
  function automatic logic [7:0] desc_attr (input logic [63:0] d); desc_attr = d[47:40]; endfunction
  function automatic logic       desc_present(input logic [7:0] a); desc_present = a[7];      endfunction
  function automatic logic [1:0] desc_dpl    (input logic [7:0] a); desc_dpl     = a[6:5];    endfunction
  function automatic logic       desc_s      (input logic [7:0] a); desc_s       = a[4];      endfunction
  function automatic logic [3:0] desc_type   (input logic [7:0] a); desc_type    = a[3:0];    endfunction
  // Type-bit helpers within a code/data (S=1) descriptor (type=a[3:0]):
  //   bit3 = executable (1=code,0=data); for code bit1=readable, for data bit1=writable.
  function automatic logic seg_is_code(input logic [7:0] a); seg_is_code = a[3]; endfunction
  function automatic logic seg_writable(input logic [7:0] a);  // data segment & W
    seg_writable = desc_s(a) && !a[3] && a[1];
  endfunction
  function automatic logic seg_readable(input logic [7:0] a);  // data, or readable code
    seg_readable = desc_s(a) && (!a[3] || a[1]);
  endfunction

  // M2S.4b — 32-bit TSS field byte-offsets for the task-switch SAVE/READ phases
  // (IA-32 SDM Vol.3 Fig.7-2). The SAVE phase writes 17 beats (no CR3); the READ
  // phase reads 18 beats (CR3 first). The GPR order eax..edi matches gpr[0..7].
  function automatic logic [7:0] tsw_save_off(input logic [4:0] beat);
    unique case (beat)
      5'd0:    tsw_save_off = 8'h20;  // EIP
      5'd1:    tsw_save_off = 8'h24;  // EFLAGS
      5'd2,5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9:
               tsw_save_off = 8'h28 + 8'({beat - 5'd2, 2'b00});  // EAX..EDI
      5'd10:   tsw_save_off = 8'h48;  // ES
      5'd11:   tsw_save_off = 8'h4C;  // CS
      5'd12:   tsw_save_off = 8'h50;  // SS
      5'd13:   tsw_save_off = 8'h54;  // DS
      5'd14:   tsw_save_off = 8'h58;  // FS
      5'd15:   tsw_save_off = 8'h5C;  // GS
      default: tsw_save_off = 8'h60;  // beat 16: LDTR
    endcase
  endfunction
  function automatic logic [7:0] tsw_read_off(input logic [4:0] beat);
    unique case (beat)
      5'd0:    tsw_read_off = 8'h1C;  // CR3
      5'd1:    tsw_read_off = 8'h20;  // EIP
      5'd2:    tsw_read_off = 8'h24;  // EFLAGS
      5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9,5'd10:
               tsw_read_off = 8'h28 + 8'({beat - 5'd3, 2'b00});  // EAX..EDI
      5'd11:   tsw_read_off = 8'h48;  // ES
      5'd12:   tsw_read_off = 8'h4C;  // CS
      5'd13:   tsw_read_off = 8'h50;  // SS
      5'd14:   tsw_read_off = 8'h54;  // DS
      5'd15:   tsw_read_off = 8'h58;  // FS
      5'd16:   tsw_read_off = 8'h5C;  // GS
      default: tsw_read_off = 8'h60;  // beat 17: LDTR
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // PROTECTED-mode descriptor-load protection DECISION (IA-32 §5 / spec §3).
  // Computes whether a MOV-to-Sreg / far-JMP descriptor load WOULD fault. This
  // is the protection *decision* (#GP/#NP/#SS selector) — it is fully computed
  // here; fault *delivery* (vectoring through the IDT) is M2S.3, so for now a
  // raised decision can only HALT (the pseg corpus loads clean descriptors, so
  // the decision is always "no fault" and the core never halts on it). Encodes
  // the architectural rules:
  //   - a NULL selector (idx 0) into DS/ES/FS/GS is legal (loads a null seg, no
  //     fault); a null selector into SS or CS is #GP.
  //   - not-present (P=0)            -> #NP (#SS for SS)
  //   - system descriptor (S=0) used as a data/stack/code segment -> #GP
  //   - SS load: must be a writable data segment, DPL==CPL==RPL          -> #GP/#SS
  //   - DS/ES/FS/GS data load: must be readable; if non-conforming code/data,
  //     max(CPL,RPL) must be <= DPL                                      -> #GP
  //   - CS (far jmp, same-priv): must be executable (code)               -> #GP
  // `is_cs` selects the CS rules, `is_ss` the SS rules; `cpl`/`rpl` are the
  // current privilege and the selector RPL.
  function automatic logic seg_load_fault(
      input logic        is_cs, input logic is_ss,
      input logic [15:0] sel,   input logic [7:0] a,
      input logic [1:0]  cpl);
    logic       nullsel;
    logic [1:0] rpl, dpl;
    logic       fault;
    begin
      nullsel = (sel[15:3] == 13'd0);   // selector index 0 (RPL/TI ignored)
      rpl     = sel[1:0];
      dpl     = desc_dpl(a);
      fault   = 1'b0;
      if (nullsel) begin
        // null in CS or SS is illegal; null in DS/ES/FS/GS is fine.
        fault = is_cs || is_ss;
      end else begin
        if (!desc_present(a))          fault = 1'b1;            // #NP / #SS
        else if (!desc_s(a))           fault = 1'b1;            // system desc as seg -> #GP
        else if (is_cs) begin
          if (!seg_is_code(a))         fault = 1'b1;            // CS must be code
        end else if (is_ss) begin
          // SS: writable data, and DPL==CPL==RPL.
          if (!seg_writable(a))        fault = 1'b1;
          else if (dpl != cpl || rpl != cpl) fault = 1'b1;
        end else begin
          // DS/ES/FS/GS: readable; privilege max(CPL,RPL) <= DPL (data/non-conf code).
          if (!seg_readable(a))        fault = 1'b1;
          else if ((cpl > dpl) || (rpl > dpl)) fault = 1'b1;
        end
      end
      seg_load_fault = fault;
    end
  endfunction

  // M2S.3 — the IDT VECTOR for a raised descriptor-load fault (companion to
  // seg_load_fault; only meaningful when that returns 1). #NP(11) when a non-SS
  // present check fails; #SS(12) when an SS present check fails; #GP(13) for
  // every other descriptor-load fault (type/privilege/null-CS-SS). A NULL DS/ES/
  // FS/GS load is legal (no fault), so it never reaches here.
  function automatic logic [7:0] seg_fault_vec(
      input logic is_cs, input logic is_ss, input logic [15:0] sel,
      input logic [7:0] a);
    logic nullsel;
    begin
      nullsel = (sel[15:3] == 13'd0);
      if (!nullsel && !desc_present(a)) seg_fault_vec = is_ss ? 8'd12 : 8'd11;
      else                              seg_fault_vec = 8'd13;   // #GP
    end
  endfunction

endpackage : ventium_sys_pkg
