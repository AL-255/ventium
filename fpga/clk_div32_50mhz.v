// clk_div32_50mhz.v -- high-speed source-compatible replacement for the
// recovered board's clk_div32 module.  The module name remains clk_div32 so
// the upstream Vivado block-design module reference does not change.
//
// It is selected only by VEN_FPGA_CORE_MHZ=50 in
// create_project_3mhz_wrapper.tcl.  Both core and HP0 derive from pl_clk0, so
// this is a synchronous 2:1 relationship, not a new CDC boundary.
`default_nettype wire
module clk_div32 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    input  wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 50000000" *)
    output wire clk_out
);
    BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) u_div2 (
        .I(clk_in), .O(clk_out), .CE(1'b1), .CLR(1'b0)
    );
endmodule
`default_nettype wire
