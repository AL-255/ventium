// ===========================================================================
// verif/srt/tb_srt.sv — standalone Verilator gate for the radix-4 SRT divider
// (fpu_x87_pkg::fx_srt_div). Drives golden vectors generated from the single-
// source model tools/srt/srt_model.py and asserts the RTL is bit-exact for BOTH
// the correct PLA (== correctly-rounded floatx80 == QEMU) and the buggy PLA (the
// documented Pentium FDIV flaw, reproduced from first principles). Independent of
// the core/SoC build; does not touch rtl/ventium*.f.
// ===========================================================================
module tb_srt;
  import fpu_x87_pkg::*;
`ifndef SRT_N
  `define SRT_N 609
`endif
  localparam int N = `SRT_N;
  logic [79:0] av [N], bv [N], ec [N], eb [N];
  int    fail;
  logic [79:0] gotc, gotb;
  initial begin
    $readmemh("build/srt/vec_a.hex",  av);
    $readmemh("build/srt/vec_b.hex",  bv);
    $readmemh("build/srt/vec_ec.hex", ec);
    $readmemh("build/srt/vec_eb.hex", eb);
    fail = 0;
    for (int i=0; i<N; i++) begin
      gotc = fx_srt_div(av[i], bv[i], 2'd0, 1'b0)[79:0];   // correct PLA
      gotb = fx_srt_div(av[i], bv[i], 2'd0, 1'b1)[79:0];   // buggy   PLA
      if (gotc !== ec[i]) begin
        fail++; if (fail<=8) $display("FAIL[%0d] correct: a=%020h b=%020h got=%020h exp=%020h", i,av[i],bv[i],gotc,ec[i]);
      end
      if (gotb !== eb[i]) begin
        fail++; if (fail<=8) $display("FAIL[%0d] buggy:   a=%020h b=%020h got=%020h exp=%020h", i,av[i],bv[i],gotb,eb[i]);
      end
    end
    // headline: the famous FDIV pair, both PLAs (vector 0).
    $display("FDIV 4195835/3145727 correct = %020h (expect 3fffaabaa0e3e35a14bd)", fx_srt_div(av[0],bv[0],2'd0,1'b0)[79:0]);
    $display("FDIV 4195835/3145727 flawed  = %020h (expect 3fffaab7f6392a768638)", fx_srt_div(av[0],bv[0],2'd0,1'b1)[79:0]);
    if (fail==0) $display("SRT-GATE-OK  (%0d vectors x 2 PLAs bit-exact vs golden)", N);
    else         $display("SRT-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end
endmodule
