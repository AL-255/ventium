// Tiny native Vivado reporting regression, not processor verification.
module clock_evidence_tb (
    input wire clk,
    input wire resetn,
    input wire [15:0] command,
    output wire [30:0] status,
    output reg [31:0] count = 0
);
    wire core_clk;
    wire [94:0] gpio_i;
    ven_programmable_clock u_clock (
        .clk_in(clk), .resetn(resetn), .safe_change(1'b1),
        .ps_gpio_o({47'd0, command, 32'd0}), .ps_gpio_i(gpio_i),
        .clk_out(core_clk)
    );
    assign status = gpio_i[94:64];
    always @(posedge core_clk) count <= count + 1'b1;
endmodule
