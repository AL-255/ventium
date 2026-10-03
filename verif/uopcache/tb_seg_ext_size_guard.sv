`default_nettype none
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Tiny standalone proof of the exact seg_ext_size mux extracted from core.sv.
// It deliberately does not model segment state, permissions, or accesses.
`timescale 1ns/1ps

module tb_seg_ext_size_guard;
  logic [7:0] seg_ext_ovr;
  logic       seg_ext_ovr_v;
  logic [3:0] cur_size;
  logic [7:0] want;
  localparam int CHECK_COUNT = 2 * 256 * 16;

  `include "seg_ext_size_extracted.svh"

  initial begin
    for (int valid = 0; valid < 2; valid++) begin
      for (int override_size = 0; override_size < 256; override_size++) begin
        for (int size = 0; size < 16; size++) begin
          seg_ext_ovr_v = valid[0];
          seg_ext_ovr = override_size[7:0];
          cur_size = size[3:0];
          #1;
          want = valid[0] ? override_size[7:0] : {4'd0, size[3:0]};
          if (seg_ext_size !== want)
            $fatal(1, "SEG-EXT-SIZE mux mismatch valid=%0d override=%0d cur=%0d got=%02x want=%02x",
                   valid, override_size, size, seg_ext_size, want);
        end
      end
    end
    if ($time != CHECK_COUNT)
      $fatal(1, "SEG-EXT-SIZE expected %0d one-ns samples, elapsed %0t",
             CHECK_COUNT, $time);
`ifdef SYNTHESIS
    $display("SEG-EXT-SIZE-MUX-OK synthesis=1 checks=%0d", CHECK_COUNT);
`else
    $display("SEG-EXT-SIZE-MUX-OK synthesis=0 checks=%0d", CHECK_COUNT);
`endif
    $finish;
  end
endmodule

`default_nettype wire
