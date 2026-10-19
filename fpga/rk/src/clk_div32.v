// clk_div32.v — derive the core clock from the 96 MHz HP0 clock by an exact integer ratio, so the
// two are SYNCHRONOUS (same source, integer 32:1 ratio, phase-related). This removes the metastable
// asynchronous core<->96 MHz crossing that made the SmartConnect's read-data CDC duplicate line
// beats; with related clocks the crossing is a synchronous multi-cycle path Vivado times exactly.
//
// The divide is /32 => ~3 MHz core. The /16 (~6 MHz) variant failed to close on the grown core
// (WNS -3.2 ns, route-dominated on the FPU register file / fragment-engine paths); at /32 the same
// place+route closes with ~+164 ns of slack. 2 cascaded BUFGCE_DIV (/8 then /4, BUFGCE_DIVIDE max
// is 8) both land on the global clock network. Verilog (not SystemVerilog): a BD module-reference
// top file must be Verilog. Module/file name kept as clk_div32 to avoid re-referencing the BD cell.
`default_nettype wire
module clk_div32 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    input  wire clk_in,    // 96 MHz (pl_clk0, also drives HP0 / dwc/acc M side); FREQ inherits from pl_clk0
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 3000000" *)
    output wire clk_out    // ~3 MHz core/SoC clock (= clk_in / 32)
);
    wire clk_div8;
    BUFGCE_DIV #(.BUFGCE_DIVIDE(8)) u_div8 (.I(clk_in),   .O(clk_div8), .CE(1'b1), .CLR(1'b0));
    BUFGCE_DIV #(.BUFGCE_DIVIDE(4)) u_div2 (.I(clk_div8), .O(clk_out),  .CE(1'b1), .CLR(1'b0));
endmodule
`default_nettype wire
