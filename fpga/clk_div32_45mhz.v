// clk_div32_45mhz.v -- 45 MHz source-compatible replacement for the
// recovered board's clk_div32 module.  The module name is deliberately kept
// identical so the upstream block-design wrapper does not change.
//
// This target is selected only by VEN_FPGA_CORE_MHZ=45 in
// create_project_3mhz_wrapper.tcl.  It derives 45 MHz from the live 100 MHz
// PL0 source with an UltraScale+ MMCM (100 * 9 / 20).  The output BUFGCE is
// held closed until the MMCM has locked, so the core's first clock edge is
// always a stable, correctly-periodic one.  No new asynchronous clock domain
// is introduced: HP0 remains on pl_clk0 and the core remains a generated
// clock of that same source.
`default_nettype wire
module clk_div32 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    input  wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 45000000" *)
    output wire clk_out
);
    wire mmcm_fb;
    wire mmcm_fb_buf;
    wire mmcm_clk;
    wire mmcm_locked;

    // VCO = 100 MHz * 9 = 900 MHz, safely inside the UltraScale+ MMCM range.
    // CLKOUT0 = 900 MHz / 20 = 45 MHz.
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(9.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(20.000),
        .DIVCLK_DIVIDE(1),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKFBOUT (mmcm_fb),
        .CLKFBOUTB(),
        .CLKOUT0  (mmcm_clk),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (mmcm_locked),
        .CLKFBIN  (mmcm_fb_buf),
        .CLKIN1   (clk_in),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_mmcm_feedback (
        .I(mmcm_fb),
        .O(mmcm_fb_buf)
    );

    BUFGCE u_mmcm_output (
        .I (mmcm_clk),
        .CE(mmcm_locked),
        .O (clk_out)
    );
endmodule
`default_nettype wire
