// Runtime integer-output-divider control for a fixed 1 GHz MMCME4 VCO.
// All logic uses the ALWAYS-ON 100 MHz reference, never the controlled clock.
// PS EMIO mailbox: command[15]=toggle, [14:7]=8'hc1, [6:0]=divide 10..50.
// Stage the data before toggling; keep it stable through acknowledgement.
// No arbitrary DRP writes, feedback changes, voltage changes, STEP or CPU fix.
module ven_pll_ctrl #(
    parameter integer TIMEOUT_BITS = 24,
    parameter integer GUARD_CYCLES = 32
) (
    input wire clk, resetn,
    input wire [15:0] command_async,
    input wire safe_change_async,
    input wire locked,
    output wire [31:0] status,
    output reg mmcm_reset,
    output reg clock_enable,
    output reg [6:0] daddr,
    output reg [15:0] di,
    output reg den, dwe,
    input wire [15:0] dout,
    input wire drdy
);
    // This bundled-data mailbox is sampled only after the request toggle has
    // crossed two flops. Software stages data >=1 ms BEFORE toggling request.
    (* ASYNC_REG = "TRUE" *) reg [15:0] cmd_meta, cmd_sync;
    (* ASYNC_REG = "TRUE" *) reg safe_meta, safe_sync;
    (* ASYNC_REG = "TRUE" *) reg lock_meta, lock_sync;
    reg [5:0] safe_count;
    wire safe_ready = safe_sync && safe_count == 6'd32;
    reg seen, ack, error, changing;
    reg [6:0] active_div, pending_div;
    reg [15:0] next08, next09;
    reg [TIMEOUT_BITS-1:0] timer;
    reg [7:0] guard;
    localparam [3:0] STARTUP=0, IDLE=1, GATE=2, RESET_WAIT=3,
        READ08=4, READ09=5, WRITE08=6, WRITE09=7, VERIFY08=8,
        VERIFY09=9, LOCK_WAIT=10, POWER_ON=11, POWER_VERIFY=12,
        POWER_FINAL=13, POWER_FINAL_VERIFY=14;
    reg [3:0] state;
    wire busy = state != IDLE;
    // 0x504c = "PL", ABI1 in bits15:14. [13]reset [12]safe [11]ack
    // [10]locked [9]error [8]busy [7]clock-enabled [6:0]last committed divider.
    assign status = {16'h504c, 2'b01, mmcm_reset, safe_ready, ack,
                     lock_sync, error, busy, clock_enable, active_div};
    wire [6:0] high_count = pending_div >> 1;
    wire [6:0] low_count = pending_div - high_count;

    initial begin
        if (TIMEOUT_BITS < 8 || TIMEOUT_BITS > 24 || GUARD_CYCLES < 4 || GUARD_CYCLES > 255)
            $fatal(1, "invalid PLL controller bounds");
    end
    always @(posedge clk) begin
        if (!resetn) begin
            cmd_meta <= 0; cmd_sync <= 0;
            safe_meta <= 0; safe_sync <= 0; safe_count <= 0;
            lock_meta <= 0; lock_sync <= 0;
        end else begin
            cmd_meta <= command_async; cmd_sync <= cmd_meta;
            safe_meta <= safe_change_async; safe_sync <= safe_meta;
            lock_meta <= locked; lock_sync <= lock_meta;
            if (!safe_sync) safe_count <= 0;
            else if (safe_count != 32) safe_count <= safe_count + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (!resetn) begin
            state <= STARTUP; guard <= 0; timer <= 0;
            seen <= 0; ack <= 0; error <= 0; changing <= 0;
            active_div <= 25; pending_div <= 25;
            next08 <= 0; next09 <= 0;
            mmcm_reset <= 1; clock_enable <= 0;
            daddr <= 0; di <= 0; den <= 0; dwe <= 0;
        end else begin
            den <= 0; dwe <= 0;
            if (state != IDLE) timer <= timer + 1'b1;
            // A failure stays clock-gated, with reset asserted. A later valid
            // command can recover via the always-on mailbox, without PCAP.
            if ((state != IDLE && &timer) ||
                (changing && !safe_ready)) begin
                state <= IDLE; error <= 1; ack <= seen;
                changing <= 0;
                mmcm_reset <= 1; clock_enable <= 0; timer <= 0;
            end else case (state)
                STARTUP: begin
                    if (guard == GUARD_CYCLES-1) begin
                        // MMCM RST does not restore its DRP registers. Reapply
                        // divide-25 even after a PS reset of an overclocked image.
                        guard <= 0; daddr <= 7'h27; di <= 16'hffff; den <= 1; dwe <= 1;
                        state <= POWER_ON; timer <= 0;
                        // A request left over across PS reset is not a new
                        // transaction. Software must toggle after startup ACK.
                        seen <= cmd_sync[15]; ack <= cmd_sync[15];
                    end else guard <= guard + 1'b1;
                end
                IDLE: if (cmd_sync[14:7] == 8'hc1 && cmd_sync[15] != seen) begin
                    seen <= cmd_sync[15]; timer <= 0; guard <= 0;
                    if (!safe_ready || cmd_sync[6:0] < 10 || cmd_sync[6:0] > 50) begin
                        // Rejection must not stop a running guest's clock.
                        ack <= cmd_sync[15]; error <= 1;
                    end else begin
                        pending_div <= cmd_sync[6:0]; error <= 0; changing <= 1;
                        clock_enable <= 0; state <= GATE;
                    end
                end
                GATE: begin
                    if (guard == GUARD_CYCLES-1) begin
                        guard <= 0; mmcm_reset <= 1; state <= RESET_WAIT;
                    end else guard <= guard + 1'b1;
                end
                RESET_WAIT: begin
                    if (guard == GUARD_CYCLES-1) begin
                        daddr <= 7'h27; di <= 16'hffff; den <= 1; dwe <= 1;
                        state <= POWER_ON; timer <= 0;
                    end else guard <= guard + 1'b1;
                end
                POWER_ON: if (drdy) begin
                    // XAPP888: enable the UltraScale+ DRP power group BEFORE
                    // changing counters. UNISIM does not enforce this rule.
                    daddr <= 7'h27; den <= 1; state <= POWER_VERIFY; timer <= 0;
                end
                POWER_VERIFY: if (drdy) begin
                    // UG572 marks only these eight bits as readable/writable;
                    // reserved bits may read X in the vendor simulation model.
                    if ((dout & 16'h9999) != 16'h9999) begin
                        state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    end else begin
                        daddr <= 7'h08; den <= 1; state <= READ08; timer <= 0;
                    end
                end
                READ08: if (drdy) begin
                    // Preserve counter enable and phase selection. UG572 0x08.
                    next08 <= {dout[15:12], high_count[5:0], low_count[5:0]};
                    daddr <= 7'h09; den <= 1; state <= READ09; timer <= 0;
                end
                READ09: if (drdy) begin
                    if (dout[15] || dout[11]) begin
                        // This image starts and stays nonfractional/no-CDDC.
                        state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    end else begin
                        // Preserve every bit except EDGE and NOCOUNT.
                        next09 <= {dout[15:8], pending_div[0], 1'b0, dout[5:0]};
                        daddr <= 7'h08; di <= next08; den <= 1; dwe <= 1;
                        state <= WRITE08; timer <= 0;
                    end
                end
                WRITE08: if (drdy) begin
                    daddr <= 7'h09; di <= next09; den <= 1; dwe <= 1;
                    state <= WRITE09; timer <= 0;
                end
                WRITE09: if (drdy) begin
                    daddr <= 7'h08; den <= 1; state <= VERIFY08; timer <= 0;
                end
                VERIFY08: if (drdy) begin
                    if (dout != next08) begin
                        state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    end else begin
                        daddr <= 7'h09; den <= 1; state <= VERIFY09; timer <= 0;
                    end
                end
                VERIFY09: if (drdy) begin
                    if (dout != next09) begin
                        state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    end else begin
                        // Keep the power group enabled through relock, matching
                        // XAPP888 and Vivado's shipped MMCM DRP implementation.
                        // Do NOT replace the full power word with a presumed
                        // static default from a subset of documented bits.
                        // These are MMCM internal enables, NOT rail voltage.
                        daddr <= 7'h27; di <= 16'hffff; den <= 1; dwe <= 1;
                        state <= POWER_FINAL; timer <= 0;
                    end
                end
                POWER_FINAL: if (drdy) begin
                    daddr <= 7'h27; den <= 1; state <= POWER_FINAL_VERIFY; timer <= 0;
                end
                POWER_FINAL_VERIFY: if (drdy) begin
                    if ((dout & 16'h9999) != 16'h9999) begin
                        state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    end else begin
                        mmcm_reset <= 0; guard <= 0; state <= LOCK_WAIT; timer <= 0;
                    end
                end
                LOCK_WAIT: begin
                    if (!lock_sync) guard <= 0;
                    else if (guard == GUARD_CYCLES-1) begin
                        active_div <= pending_div; clock_enable <= 1;
                        ack <= seen; error <= 0; state <= IDLE; timer <= 0; changing <= 0;
                    end else guard <= guard + 1'b1;
                end
                default: begin
                    state <= IDLE; error <= 1; ack <= seen; changing <= 0;
                    mmcm_reset <= 1; clock_enable <= 0;
                end
            endcase
        end
    end
endmodule
