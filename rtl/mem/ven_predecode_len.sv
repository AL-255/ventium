`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// mem/ven_predecode_len.sv -- bounded, fail-closed x86 length scanner.
//
// This leaf is deliberately NOT an instruction decoder.  It is used only by
// uopcache's fill-time walker after decode.sv has said that the current bytes
// are not an executable fast-path fpd_t.  A known result means only that the
// complete legacy x86 encoding is known to occupy `len` bytes.  The fixed
// six-byte input holds only the opcode metadata (prefixes, opcode, ModR/M and
// SIB); a known long form never depends on unobserved displacement/immediate
// contents.  The caller additionally proves the resulting span stays within
// its physical I-cache line, leaves that start unmapped, and lets the
// established slow S_FETCH/S_DECODE path execute it.
//
// Consequently an unsupported or incomplete grammar MUST return known=0.  A
// wrong positive length could manufacture a later executable boundary; a false
// negative merely loses uop-cache coverage.  Keep the input bounded to six
// bytes: this avoids a wide line-byte selector in the fill-side timing path.
//
// `short_sfetch_safe` is deliberately MUCH narrower than `known`.  It marks an
// exact two-byte REP MOVS/STOS form whose normal slow decoder consumes no
// suffix bytes.  The uop cache may retain that length in an otherwise-invalid
// byte-map entry, allowing S_FETCH to copy just the two resident bytes before
// entering the ordinary S_DECODE/S_EXEC string path.  It never creates an
// executable uop-cache hit and must not grow into a generic scanner-to-decoder
// contract without a separate equivalence proof.

module ven_predecode_len #(
    // Default-off experiment: exact two-byte FF /7 register encodings are
    // architecturally #UD, so their known length can safely preserve a later
    // independently executable boundary.  This is deliberately not a generic
    // reserved-opcode rule; see the narrow arm in the one-byte map below.
    parameter bit RESYNC_FIXED_UD = 1'b0
) (
    input  logic [47:0] bytes,       // fixed metadata window; byte 0 is [7:0]
    input  logic        def16,       // default operand/address size
    output logic        known,       // complete, audited grammar <= ten bytes
    output logic [3:0]  len,
    output logic        short_sfetch_safe
);

  import ventium_decode_pkg::*;
  import ventium_sys_pkg::*;

  // A guarded accessor keeps all metadata look-ahead within the fixed six-byte
  // window.  A caller must still ensure len fits the physical I-cache-line
  // tail before consuming it.
  function automatic logic [7:0] byte_at(
      input logic [47:0] win, input logic [3:0] idx);
    if (idx < 4'd6) byte_at = win[idx*8 +: 8];
    else             byte_at = 8'h00;
  endfunction

  logic [3:0] pfx_len;
  logic       pfx_opsize, pfx_addr;
  logic       eff_opsize, eff_addr;
  logic [7:0] op0, op1, modrm, sib;
  logic [3:0] base_len, mrm_len, imm_len;
  logic [4:0] total_len;
  logic       has_modrm, candidate, meta_fits;
  logic       has_sib;

  // The fill walker may skip a known slow encoding up to ten bytes long.  This
  // covers the common ModR/M+SIB+disp32 and imm32 forms that previously cut a
  // line walk short, while retaining a compact fixed metadata window.  The
  // metadata guard below is mandatory: trailing displacement/immediate bytes
  // may be unobserved, but no byte used to derive their span may be padded.
  localparam logic [4:0] SCAN_MAX_LEN = 5'd10;

  always_comb begin
    // Prefix grammar mirrors decode_stages.sv: accept at most four legacy
    // prefixes.  The hardware decoder records prefix presence, not parity;
    // repeated 66/67 therefore still select the overridden size once.
    pfx_len    = 4'd0;
    pfx_opsize = 1'b0;
    pfx_addr   = 1'b0;
    for (int i=0; i<4; i++) begin
      if ((pfx_len == i[3:0]) && is_prefix(byte_at(bytes, i[3:0]))) begin
        if (byte_at(bytes, i[3:0]) == 8'h66) pfx_opsize = 1'b1;
        if (byte_at(bytes, i[3:0]) == 8'h67) pfx_addr   = 1'b1;
        pfx_len = pfx_len + 4'd1;
      end
    end

    eff_opsize = def16 ^ pfx_opsize;
    eff_addr   = def16 ^ pfx_addr;
    op0        = byte_at(bytes, pfx_len);
    op1        = byte_at(bytes, pfx_len + 4'd1);

    // Defaults are fail-closed.  `base_len` includes prefixes and opcode
    // bytes, mrm_len includes ModR/M+SIB+displacement, and imm_len is the
    // instruction-specific trailing immediate/relative field.
    base_len   = pfx_len + 4'd1;
    has_modrm  = 1'b0;
    imm_len    = 4'd0;
    candidate  = 1'b0;
    modrm      = byte_at(bytes, pfx_len + 4'd1);
    sib        = byte_at(bytes, pfx_len + 4'd2);
    has_sib    = !eff_addr && (modrm[7:6] != 2'b11) && (modrm[2:0] == 3'b100);
    mrm_len    = mfl_e(eff_addr, modrm[7:6], modrm[2:0], has_sib, sib[2:0]);
    meta_fits  = 1'b1;

    // A fifth legacy prefix is intentionally unknown.  `op0` cannot otherwise
    // be a prefix: the bounded prefix loop above would already have consumed it.
    if (!is_prefix(op0)) begin
      if (op0 == 8'h0F) begin
        // Two-byte map.  Do not accept 0F 38/3A or future maps until each has
        // a separately audited grammar; treating them as generic ModR/M is not
        // safe because their immediate rules differ.
        base_len  = pfx_len + 4'd2;
        modrm     = byte_at(bytes, pfx_len + 4'd2);
        sib       = byte_at(bytes, pfx_len + 4'd3);
        has_sib   = !eff_addr && (modrm[7:6] != 2'b11) && (modrm[2:0] == 3'b100);
        mrm_len   = mfl_e(eff_addr, modrm[7:6], modrm[2:0], has_sib, sib[2:0]);

        unique case (op1)
          // fixed two-byte system/control forms
          8'h06, 8'h08, 8'h09, 8'h0B, 8'hAA,
          8'h31, 8'hA0, 8'hA1, 8'hA2, 8'hA8, 8'hA9,
          8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCC, 8'hCD, 8'hCE, 8'hCF:
            candidate = 1'b1;

          // relative Jcc: operand-size displacement
          8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85, 8'h86, 8'h87,
          8'h88, 8'h89, 8'h8A, 8'h8B, 8'h8C, 8'h8D, 8'h8E, 8'h8F: begin
            candidate = 1'b1;
            imm_len   = eff_opsize ? 4'd2 : 4'd4;
          end

          // Audited ModR/M-only families.  Deliberately do NOT include 0F 00
          // or 0F 01: their legal subforms are mode/state dependent and rejected
          // forms in decode_stages.sv do not uniformly consume a full addressing
          // grammar.  Losing those rare system boundaries is safe; inventing one
          // after a #UD is not.
          8'h1E, 8'h1F,
          8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97,
          8'h98, 8'h99, 8'h9A, 8'h9B, 8'h9C, 8'h9D, 8'h9E, 8'h9F,
          8'hA3, 8'hA5, 8'hAB, 8'hAD, 8'hAF,
          8'hB0, 8'hB1, 8'hB6, 8'hB7, 8'hBB,
          8'hBC, 8'hBD, 8'hBE, 8'hBF,
          8'hC0, 8'hC1:
            begin has_modrm = 1'b1; candidate = 1'b1; end

          // Group 8 has an imm8 only for BT/BTS/BTR/BTC selectors /4..7.
          8'hBA: begin
            if (modrm[5:3] >= 3'd4) begin
              has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1;
            end
          end

          // SHLD/SHRD immediate forms have a trailing imm8; CL forms above
          // share the ordinary ModR/M-only grammar.
          8'hA4, 8'hAC: begin
            has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1;
          end

          // CMPXCHG8B is 0F C7 /1 with a memory operand. Other selectors and
          // the register form (the F00F encoding) are deliberately unknown.
          8'hC7: begin
            if ((modrm[5:3] == 3'd1) && (modrm[7:6] != 2'b11)) begin
              has_modrm = 1'b1; candidate = 1'b1;
            end
          end
          default: ;
        endcase
      end else begin
        // One-byte map.  Every accepted family has a P5/slow-decoder grammar
        // independent of the actual semantic implementation.  Do not turn this
        // into a broad default "has ModR/M" arm: unknown encodings must stop.
        unique case (op0)
          // ALU r/m,r and r,r/m forms.
          8'h00, 8'h01, 8'h02, 8'h03,
          8'h08, 8'h09, 8'h0A, 8'h0B,
          8'h10, 8'h11, 8'h12, 8'h13,
          8'h18, 8'h19, 8'h1A, 8'h1B,
          8'h20, 8'h21, 8'h22, 8'h23,
          8'h28, 8'h29, 8'h2A, 8'h2B,
          8'h30, 8'h31, 8'h32, 8'h33,
          8'h38, 8'h39, 8'h3A, 8'h3B,
          8'h84, 8'h85, 8'h86, 8'h87,
          8'h88, 8'h89, 8'h8A, 8'h8B,
          8'hD0, 8'hD1, 8'hD2, 8'hD3,
          8'hD8, 8'hD9, 8'hDA, 8'hDB, 8'hDC, 8'hDD, 8'hDE, 8'hDF:
            begin has_modrm = 1'b1; candidate = 1'b1; end

          // BOUND, LEA and LES/LDS require a memory operand.  Decode-stage
          // reject paths for register forms are not a generic ModR/M length
          // contract, so leave those encodings unmapped.
          8'h62, 8'h8D, 8'hC4, 8'hC5: begin
            if (modrm[7:6] != 2'b11) begin has_modrm = 1'b1; candidate = 1'b1; end
          end

          // MOV from Sreg allows ES/CS/SS/DS/FS/GS; MOV to Sreg excludes CS.
          // Reserved segment selectors must not create a boundary past #UD.
          8'h8C: begin
            if (modrm[5:3] <= 3'd5) begin has_modrm = 1'b1; candidate = 1'b1; end
          end
          8'h8E: begin
            if ((modrm[5:3] == 3'd0) || (modrm[5:3] >= 3'd2 && modrm[5:3] <= 3'd5)) begin
              has_modrm = 1'b1; candidate = 1'b1;
            end
          end

          // Group 4 has only INC (/0) and DEC (/1).  Group 5 has INC/DEC,
          // near CALL/JMP, PUSH, and memory-only far CALL/JMP; /7 is invalid.
          8'hFE: begin
            if (modrm[5:3] <= 3'd1) begin has_modrm = 1'b1; candidate = 1'b1; end
          end
          8'hFF: begin
            if ((modrm[5:3] <= 3'd2) || (modrm[5:3] == 3'd4) || (modrm[5:3] == 3'd6)
                || (((modrm[5:3] == 3'd3) || (modrm[5:3] == 3'd5))
                    && (modrm[7:6] != 2'b11))
                // The sole optional resynchronization exception is FF /7
                // with a register ModR/M.  Its complete span is exactly
                // prefixes + opcode + ModR/M; it has no SIB/displacement/
                // immediate and the slow decoder already raises #UD.  Leave
                // both bytes unmapped; this only lets a later byte boundary
                // be cached.  Memory /7 forms remain fail-closed.
                || (RESYNC_FIXED_UD && (modrm[7:6] == 2'b11)
                    && (modrm[5:3] == 3'd7))) begin
              has_modrm = 1'b1; candidate = 1'b1;
            end
          end

          // IMUL r,r/m,imm and its imm8 variant.
          8'h69: begin
            // decode_stages.sv's implemented IMUL-imm path currently consumes
            // imm32 only.  Do not let this walker use the architectural imm16
            // form until that slow-path length contract is corrected and gated.
            if (!eff_opsize) begin
              has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd4;
            end
          end
          8'h6B: begin has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1; end

          // Group 1 ALU immediate forms.
          8'h80, 8'h82, 8'h83: begin has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1; end
          8'h81: begin
            has_modrm = 1'b1; candidate = 1'b1;
            imm_len = eff_opsize ? 4'd2 : 4'd4;
          end

          // POP r/m is /0 only; keeping other selectors unknown is conservative.
          8'h8F: begin
            if (modrm[5:3] == 3'd0) begin has_modrm = 1'b1; candidate = 1'b1; end
          end

          // Shift immediate and MOV r/m,imm groups, restricted to legal MOV /0.
          8'hC0, 8'hC1: begin has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1; end
          8'hC6: begin
            if (modrm[5:3] == 3'd0) begin has_modrm = 1'b1; candidate = 1'b1; imm_len = 4'd1; end
          end
          8'hC7: begin
            if (modrm[5:3] == 3'd0) begin
              has_modrm = 1'b1; candidate = 1'b1;
              imm_len = eff_opsize ? 4'd2 : 4'd4;
            end
          end

          // Group 3.  TEST /0,/1 carries an immediate; NOT/NEG/MUL/IMUL/DIV/
          // IDIV (/2..7) are ModR/M-only.  The slow decoder intentionally
          // accepts /1 as TEST too, so retaining it here keeps both paths'
          // grammar identical.
          8'hF6: begin
            has_modrm = 1'b1; candidate = 1'b1;
            if (modrm[5:3] <= 3'd1) imm_len = 4'd1;
          end
          8'hF7: begin
            has_modrm = 1'b1; candidate = 1'b1;
            if (modrm[5:3] <= 3'd1) imm_len = eff_opsize ? 4'd2 : 4'd4;
          end

          // accumulator immediate byte forms
          8'h04, 8'h0C, 8'h14, 8'h1C, 8'h24, 8'h2C, 8'h34, 8'h3C,
          8'hA8:
            begin candidate = 1'b1; imm_len = 4'd1; end

          // accumulator immediate operand-size forms, CALL/JMP relative,
          // and TEST eAX,imm.
          8'h05, 8'h0D, 8'h15, 8'h1D, 8'h25, 8'h2D, 8'h35, 8'h3D,
          8'hA9, 8'hE8, 8'hE9:
            begin candidate = 1'b1; imm_len = eff_opsize ? 4'd2 : 4'd4; end

          // short branches / port-immediate I/O / INT imm8.
          8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77,
          8'h78, 8'h79, 8'h7A, 8'h7B, 8'h7C, 8'h7D, 8'h7E, 8'h7F,
          8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hEB,
          8'hE4, 8'hE5, 8'hE6, 8'hE7,
          8'hCD, 8'hD4, 8'hD5:
            begin candidate = 1'b1; imm_len = 4'd1; end

          // moffs uses effective ADDRESS size, not operand size.
          8'hA0, 8'hA1, 8'hA2, 8'hA3:
            begin candidate = 1'b1; imm_len = eff_addr ? 4'd2 : 4'd4; end

          // register immediate forms.
          8'hB0, 8'hB1, 8'hB2, 8'hB3, 8'hB4, 8'hB5, 8'hB6, 8'hB7:
            begin candidate = 1'b1; imm_len = 4'd1; end
          8'hB8, 8'hB9, 8'hBA, 8'hBB, 8'hBC, 8'hBD, 8'hBE, 8'hBF:
            begin candidate = 1'b1; imm_len = eff_opsize ? 4'd2 : 4'd4; end
          8'h68:
            begin candidate = 1'b1; imm_len = eff_opsize ? 4'd2 : 4'd4; end
          8'h6A:
            begin candidate = 1'b1; imm_len = 4'd1; end

          // far CALL/JMP pointer (offset selected by operand size) and return
          // immediates / ENTER.
          8'h9A, 8'hEA:
            begin candidate = 1'b1; imm_len = (eff_opsize ? 4'd2 : 4'd4) + 4'd2; end
          8'hC2, 8'hCA:
            begin candidate = 1'b1; imm_len = 4'd2; end
          8'hC8:
            begin candidate = 1'b1; imm_len = 4'd3; end

          // exact one-byte P5 grammar (stack/flags/string/control/I/O-DX).
          8'h06, 8'h07, 8'h0E, 8'h16, 8'h17, 8'h1E, 8'h1F,
          8'h27, 8'h2F, 8'h37, 8'h3F,
          8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47,
          8'h48, 8'h49, 8'h4A, 8'h4B, 8'h4C, 8'h4D, 8'h4E, 8'h4F,
          8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57,
          8'h58, 8'h59, 8'h5A, 8'h5B, 8'h5C, 8'h5D, 8'h5E, 8'h5F,
          8'h60, 8'h61,
          8'h6C, 8'h6D, 8'h6E, 8'h6F,
          8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h97,
          8'h98, 8'h99, 8'h9B, 8'h9C, 8'h9D, 8'h9E, 8'h9F,
          8'hA4, 8'hA5, 8'hA6, 8'hA7, 8'hAA, 8'hAB, 8'hAC, 8'hAD, 8'hAE, 8'hAF,
          8'hC3, 8'hC9, 8'hCB, 8'hCC, 8'hCE, 8'hCF, 8'hD7,
          8'hEC, 8'hED, 8'hEE, 8'hEF,
          8'hF4, 8'hF5, 8'hF8, 8'hF9, 8'hFA, 8'hFB, 8'hFC, 8'hFD:
            candidate = 1'b1;
          default: ;
        endcase
      end
    end

    total_len = {1'b0,base_len} + (has_modrm ? {1'b0,mrm_len} : 5'd0)
                + {1'b0,imm_len};
    // The scanner only needs opcode/ModR/M/SIB metadata to know an
    // instruction's total span; it never interprets bytes in its trailing
    // displacement or immediate.  It must nevertheless prove that every
    // metadata byte it DID inspect lies in `bytes` -- byte_at deliberately
    // returns zero out of range, which must never create a positive result.
    if (has_modrm) begin
      if (op0 == 8'h0F) begin
        if (pfx_len > 4'd3) meta_fits = 1'b0;       // ModR/M = pfx + 2
        if (has_sib && (pfx_len > 4'd2)) meta_fits = 1'b0; // SIB = pfx + 3
      end else begin
        if (pfx_len > 4'd4) meta_fits = 1'b0;       // ModR/M = pfx + 1
        if (has_sib && (pfx_len > 4'd3)) meta_fits = 1'b0; // SIB = pfx + 2
      end
    end
    // Zero/oversize results are not useful to the bounded walker.  A positive
    // 7..10-byte result consumes only a *slow* encoding after its metadata has
    // been proven resident; it never turns an incomplete input window into an
    // executable boundary.
    known = candidate && meta_fits && (total_len != 5'd0) && (total_len <= SCAN_MAX_LEN);
    len   = known ? total_len[3:0] : 4'd0;

    // The length scanner is intentionally broad enough to resynchronize the
    // fill walker.  Only this exact, prefix-minimal string subset is also safe
    // to feed a zero-padded slow decode: it has one REP-class prefix, one
    // opcode byte, no ModR/M/EA/immediate, and decode_stages.sv consumes
    // precisely pfx_len+1 bytes for K_STR.  Reject operand/address/segment/LOCK
    // and repeated-prefix spellings rather than relying on their incidental
    // length; the slow path remains the universal fallback.
    short_sfetch_safe = known && (len == 4'd2) && (pfx_len == 4'd1)
                     && ((bytes[7:0] == 8'hF2) || (bytes[7:0] == 8'hF3))
                     && ((op0 == 8'hA4) || (op0 == 8'hA5)
                      || (op0 == 8'hAA) || (op0 == 8'hAB));
`ifdef VEN_UOP_SLOW_LEN_HINT
    // Default-off extension, proven against every decode_stages output with
    // arbitrary suffix bytes. No prefixes/default16/register x87/reserved
    // escapes: only complete memory ModR/M forms whose entire slow descriptor
    // is instruction-local. Reuse the scanner's length, never infer execution.
    // CALL/RET deliberately stay out: even their unused EA scratch outputs can
    // depend on trailing bytes in the current authoritative slow decoder.
    if (known && !def16 && (pfx_len == 4'd0) && (modrm[7:6] != 2'b11)) begin
      unique case (op0)
        8'hD8, 8'hDA, 8'hDC, 8'hDE: short_sfetch_safe = 1'b1;
        8'hD9, 8'hDF:
          if (modrm[5:3] != 3'd1) short_sfetch_safe = 1'b1;
        8'hDD:
          if ((modrm[5:3] != 3'd1) && (modrm[5:3] != 3'd5)) short_sfetch_safe = 1'b1;
        8'hDB:
          if ((modrm[5:3] == 3'd0) || (modrm[5:3] == 3'd2) ||
              (modrm[5:3] == 3'd3) || (modrm[5:3] == 3'd5) ||
              (modrm[5:3] == 3'd7)) short_sfetch_safe = 1'b1;
        8'h0F:
          if ((op1 == 8'hB6) || (op1 == 8'hB7) ||
              (op1 == 8'hBE) || (op1 == 8'hBF)) short_sfetch_safe = 1'b1;
        default: ;
      endcase
    end
`endif
  end

endmodule : ven_predecode_len
`default_nettype wire
