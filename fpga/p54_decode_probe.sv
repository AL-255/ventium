`default_nettype none
// Register-to-register timing wrapper for the existing fast decoder. Not RTL
// in the processor filelist; the identical wrapper is used for both profiles.
module p54_decode_probe
  import ventium_pkg::*;
  import ventium_decode_pkg::*;
(
    input  wire logic        clk,
    input  wire logic [55:0] bytes_in,
    input  wire logic [31:0] flags_in,
    input  wire logic        def16_in,
    input  wire logic        cycle_mode_in,
    output      logic [$bits(fpd_t)-1:0] uop_out
);
  logic [55:0] bytes_q;
  logic [31:0] flags_q;
  logic def16_q, cycle_mode_q;
  fpd_t decoded, uop_q;
  always_ff @(posedge clk) begin
    bytes_q <= bytes_in;
    flags_q <= flags_in;
    def16_q <= def16_in;
    cycle_mode_q <= cycle_mode_in;
    uop_q <= decoded;
  end
  decode u_decode (
      .ib0(bytes_q[7:0]), .ib1(bytes_q[15:8]),
      .ib2(bytes_q[23:16]), .ib3(bytes_q[31:24]),
      .ib4(bytes_q[39:32]), .ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]), .iflags(flags_q),
      .def16(def16_q), .cycle_mode(cycle_mode_q), .uop(decoded));
  assign uop_out = uop_q;
endmodule
`default_nettype wire
