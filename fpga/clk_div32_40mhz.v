// clk_div32_40mhz.v -- 40 MHz source-compatible replacement for the
// recovered board's clk_div32 module.  The module name is deliberately kept
// identical so the upstream block-design wrapper does not change.
//
// This target is selected only by VEN_FPGA_CORE_MHZ=40 in
// create_project_3mhz_wrapper.tcl.  It derives 40 MHz from the live 100 MHz
// PL0 source with an UltraScale+ MMCM (100 * 10 / 25).  The output BUFGCE is
// held closed until the MMCM has locked.  HP0 remains on pl_clk0 and the
// core clock remains a generated clock of that same source.
`default_nettype wire
module clk_div32 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    input  wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 40000000" *)
    output wire clk_out
);
    wire mmcm_fb;
    wire mmcm_fb_buf;
    wire mmcm_clk;
    wire mmcm_locked;

    // VCO = 100 MHz * 10 = 1000 MHz, inside the UltraScale+ MMCM range.
    // CLKOUT0 = 1000 MHz / 25 = 40 MHz.  The input must actually be 100 MHz;
    // changing only a clock constraint or interface label cannot ensure this.
    // Do not select an 800 MHz boundary VCO: PS configuration can model PL0
    // slightly below 100 MHz even when Linux's live clock is nominally 100 MHz.
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(10.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(25.000),
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
