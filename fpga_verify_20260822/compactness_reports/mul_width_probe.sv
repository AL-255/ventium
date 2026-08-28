`default_nettype none

(* use_dsp = "yes" *)
module mul_width_probe_wide (
    input  wire logic [63:0]  a,
    input  wire logic [63:0]  b,
    output logic [127:0] y
);
  assign y = {64'd0, a} * {64'd0, b};
endmodule

(* use_dsp = "yes" *)
module mul_width_probe_narrow (
    input  wire logic [63:0]  a,
    input  wire logic [63:0]  b,
    output logic [127:0] y
);
  assign y = a * b;
endmodule

`default_nettype wire
