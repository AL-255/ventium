`timescale 1ps/1ps
module tb_clock40;
    reg clk_in = 1'b0;
    reg clock_enable = 1'b0;
    wire clk_out;
    integer output_edges = 0;
    integer steady_periods = 0;
    time previous_edge;
    time locked_at;
    clk_div32 dut (.clk_in(clk_in), .clk_out(clk_out));

    // Ordinary input pins only; no force/deposit or substitute primitives.
    always #5000 begin
        if (clock_enable) clk_in = ~clk_in;
        else clk_in = 1'b0;
    end
    always @(posedge clk_out) begin
        output_edges = output_edges + 1;
        if (dut.mmcm_locked !== 1'b1)
            $fatal(1, "output edge without LOCKED");
    end
    initial begin
        #300000;
        if (output_edges != 0 || clk_out !== 1'b0)
            $fatal(1, "output was not gated during initial absent input clock");
        clock_enable = 1'b1;
        wait (dut.mmcm_locked === 1'b1);
        locked_at = $time;
        @(posedge clk_out);
        previous_edge = $time;
        repeat (200) begin
            @(posedge clk_out);
            if ($time - previous_edge != 25000)
                $fatal(1, "period=%0t ps, expected 25000", $time-previous_edge);
            if (dut.mmcm_locked !== 1'b1)
                $fatal(1, "lock lost during stable input");
            previous_edge = $time;
            steady_periods = steady_periods + 1;
        end
        $display("CLOCK40-PRIMITIVE-OK locked_at_ps=%0t periods=%0d period_ps=25000 input_ps=10000 output_edges=%0d", locked_at, steady_periods, output_edges);
        $display("LIMIT: RST/PWRDWN are tied low in production module; this tests initial startup and stable input, not an external reset/relock guarantee.");
        $finish;
    end
    initial begin
        #120000000;
        $fatal(1, "clock primitive startup/steady timeout");
    end
endmodule
