// One 40 MHz image; PS EMIO controls CLKOUT0 at run time. AXI stays 100 MHz.
// EMIO32..47 (GPIO110..125) = command; EMIO64..94 (GPIO142..172) = status[30:0].
// Vivado's PS IP caps exposed EMIO at 95 lines. Status[31] is constant zero.
// The lower EMIO bank belongs to board LEDs/buttons and is NOT used here.
module ven_programmable_clock (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    input wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input wire resetn,
    input wire safe_change,
    input wire [94:0] ps_gpio_o,
    output wire [94:0] ps_gpio_i,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 40000000" *)
    output wire clk_out
);
    reg [7:0] startup = 8'd0;
    always @(posedge clk_in or negedge resetn)
        if (!resetn) startup <= 0;
        else startup <= {startup[6:0], 1'b1};
    wire mmcm_fb, mmcm_fb_buf, mmcm_clk, locked;
    wire mmcm_reset, clock_enable, den, dwe, drdy;
    wire [6:0] daddr;
    wire [15:0] di, dout;
    wire [31:0] status;
    assign ps_gpio_i = {status[30:0], 64'd0};
    ven_pll_ctrl u_control (
        .clk(clk_in), .resetn(startup[7]), .command_async(ps_gpio_o[47:32]),
        .safe_change_async(safe_change), .locked(locked), .status(status),
        .mmcm_reset(mmcm_reset), .clock_enable(clock_enable),
        .daddr(daddr), .di(di), .den(den), .dwe(dwe), .dout(dout), .drdy(drdy)
    );
    MMCME4_ADV #(
        .BANDWIDTH("OPTIMIZED"), .CLKFBOUT_MULT_F(10.000),
        .CLKIN1_PERIOD(10.000), .CLKOUT0_DIVIDE_F(25.000),
        .DIVCLK_DIVIDE(1), .REF_JITTER1(0.010), .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKFBOUT(mmcm_fb), .CLKFBOUTB(), .CLKOUT0(mmcm_clk), .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(locked),
        .CLKFBIN(mmcm_fb_buf), .CLKIN1(clk_in), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .PWRDWN(1'b0), .RST(mmcm_reset),
        .DCLK(clk_in), .DADDR(daddr), .DI(di), .DEN(den), .DWE(dwe), .DO(dout), .DRDY(drdy),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
        .CDDCREQ(1'b0), .CDDCDONE(), .CLKINSTOPPED(), .CLKFBSTOPPED()
    );
    BUFG u_mmcm_feedback (.I(mmcm_fb), .O(mmcm_fb_buf));
    BUFGCE u_mmcm_output (.I(mmcm_clk), .CE(locked & clock_enable), .O(clk_out));
endmodule
