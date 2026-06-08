// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/decpipe/tb_fplen.sv — exhaustive equivalence gate for the +VEN_DEC_PIPE
// length-only sub-decoder ventium_decode_pkg::fp_len (step 1, the #1 correctness
// footgun). Instantiates the REAL fast-path `decode` module (whose uop.len IS
// fp_decode's length) and asserts fp_len(b0,b1,cyc) == decode.uop.len for EVERY
// (b0, b1, cycle_mode) — 256x256x2 cases — and that the length is independent of
// b2..b5/flags (a sanity sweep). A single mismatch would mis-position the V
// candidate in the decode-pipeline queue and silently diverge. Prints FPLEN-GATE-OK.

module tb_fplen
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
();
  logic [7:0]  ib0, ib1, ib2, ib3, ib4, ib5;
  logic [31:0] iflags;
  logic        cyc;
  fpd_t        uop;

  decode dut (.ib0, .ib1, .ib2, .ib3, .ib4, .ib5, .iflags, .cycle_mode(cyc), .uop);

  int errors = 0;
  initial begin
    ib2 = 8'h55; ib3 = 8'hAA; ib4 = 8'h12; ib5 = 8'h34; iflags = 32'h0;
    // exhaustive (b0, b1, cycle_mode)
    for (int c = 0; c < 2; c++) begin
      cyc = c[0];
      for (int x = 0; x < 256; x++) begin
        for (int y = 0; y < 256; y++) begin
          ib0 = x[7:0]; ib1 = y[7:0]; #1;
          if (uop.len !== fp_len(ib0, ib1, cyc)) begin
            if (errors < 25)
              $display("  MISMATCH b0=%02x b1=%02x cyc=%0d: decode.len=%0d fp_len=%0d",
                       ib0, ib1, cyc, uop.len, fp_len(ib0, ib1, cyc));
            errors++;
          end
        end
      end
    end
    // sanity: length is independent of b2..b5 + flags (vary them on a len-6 arm)
    ib0 = 8'h81; ib1 = 8'hC0; cyc = 1'b1;  // grp1 r/m32,imm32 reg form (len 6)
    for (int k = 0; k < 256; k++) begin
      ib2 = k[7:0]; ib3 = ~k[7:0]; ib4 = k[7:0]; ib5 = ~k[7:0];
      iflags = {k[7:0], 24'h0}; #1;
      if (uop.len !== fp_len(ib0, ib1, cyc)) errors++;
    end

    if (errors == 0) $display("FPLEN-GATE-OK (fp_len == fp_decode.len over all b0,b1,cyc)");
    else             $display("FPLEN-GATE-FAIL (%0d mismatches)", errors);
    $finish;
  end
endmodule
