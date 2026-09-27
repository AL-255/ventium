`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// ven_axi2avalon.sv — AXI4 (Ventium ven_axi_master) → Avalon-MM burst (ao486 avm_*)
//
// Bridges the Ventium core's production DDR port (m_axi_*, via ventium_l1_axi built
// with identity REMAP_BASE so the AXI address IS the x86 physical byte address) onto
// the ao486 SoC's CPU memory seam (the `avm_*` group that `l2_cache` serves — which
// keeps doing all DDR / VGA-aperture / BIOS-shadow routing). See VENTIUM_SWAP.md §4.1.
//
// Ventium's ven_axi_master issues (docs/rtl-interface.md, ven_axi_master.sv):
//   READ  = one INCR or WRAP8 burst, ARLEN=7 (8 beats), ARSIZE=2 (4 B/beat)
//           → a 32 B line fill.  A WRAP8 begins at the critical dword; Avalon
//             only has incrementing bursts, so this bridge emits the high and
//             low line fragments as two Avalon commands while keeping one AXI R
//             response stream.
//   WRITE = one single beat, AWLEN=0, AWSIZE=2, WSTRB verbatim
// and issues them serially (one outstanding), with registered VALIDs. So this bridge
// handles one read OR one write at a time — sufficient and simplest; pipeline later.
//
// Avalon-MM master semantics (ao486 avalon_mem.v / l2_cache CPU port):
//   address = 30-bit DWORD address (byte>>2); burstcount = beats; command accepted
//   the cycle waitrequest is low; reads return `burstcount` readdatavalid pulses.
//
// A20 is applied by the shim on the AXI address BEFORE this bridge (Ventium defers it).

module ven_axi2avalon (
    input  logic        clk,
    input  logic        rst_n,

    // ---- AXI4 slave side (from Ventium m_axi_*) ----------------------------
    // Write address
    input  logic [3:0]  s_axi_awid,
    input  logic [39:0] s_axi_awaddr,     // byte address (identity == x86 phys)
    input  logic [7:0]  s_axi_awlen,      // expect 0 (single)
    input  logic [2:0]  s_axi_awsize,     // expect 2 (4 B)
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    // Write data
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    // Write response
    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    // Read address
    input  logic [3:0]  s_axi_arid,
    input  logic [39:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,      // expect 7 (8 beats) or 0
    input  logic [2:0]  s_axi_arsize,     // expect 2 (4 B)
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    // Read data
    output logic [3:0]  s_axi_rid,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // ---- Avalon-MM master side (to ao486 avm_* / l2_cache) -----------------
    output logic [29:0] avm_address,      // DWORD address
    output logic [31:0] avm_writedata,
    output logic [3:0]  avm_byteenable,
    output logic [3:0]  avm_burstcount,
    output logic        avm_write,
    output logic        avm_read,
    input  logic        avm_waitrequest,
    input  logic        avm_readdatavalid,
    input  logic [31:0] avm_readdata
);

    localparam logic [1:0] RESP_OKAY = 2'b00;

    typedef enum logic [2:0] {
        S_IDLE,      // arbitrate a pending read or write
        S_RD_CMD,    // drive avm_read+burstcount until accepted (waitrequest low)
        S_RD_DATA,   // stream readdatavalid beats out on the R channel
        S_WR_CMD,    // wait for W data, drive avm_write until accepted
        S_WR_RESP    // drive B
    } state_e;

    state_e       state;
    logic [3:0]   id_q;          // captured AWID/ARID for the response
    logic [29:0]  addr_q;        // captured DWORD address
    logic [3:0]   len_q;         // beats remaining to return on a read (1..8)
    logic [3:0]   cmd_beats;     // current Avalon command's read beats
    logic [3:0]   cmd_left;      // beats still owed by that Avalon command
    logic [3:0]   wrap_low_beats;// low fragment after the first WRAP8 fragment
    logic         wrap_pending;  // issue the low line fragment after this command

    // ---- Address-phase acceptance: only when idle, read has priority. -------
    assign s_axi_arready = (state == S_IDLE);
    // Accept the write-address only when idle AND no read is competing this cycle.
    assign s_axi_awready = (state == S_IDLE) && !s_axi_arvalid;

    // ---- Avalon command outputs (registered address, combinational strobes) -
    assign avm_address    = addr_q;
    assign avm_burstcount = (state == S_RD_CMD) ? cmd_beats : 4'd1;
    assign avm_read       = (state == S_RD_CMD);
    assign avm_write      = (state == S_WR_CMD) && s_axi_wvalid;

    // Write data path (single beat)
    assign avm_writedata  = s_axi_wdata;
    assign avm_byteenable = s_axi_wstrb;
    assign s_axi_wready   = (state == S_WR_CMD) && !avm_waitrequest;

    // Read-data (R) channel
    assign s_axi_rdata    = avm_readdata;
    assign s_axi_rresp    = RESP_OKAY;
    assign s_axi_rid      = id_q;
    assign s_axi_rvalid   = (state == S_RD_DATA) && avm_readdatavalid;
    assign s_axi_rlast    = (state == S_RD_DATA) && avm_readdatavalid && (len_q == 4'd1);

    // Write-response (B) channel
    assign s_axi_bid      = id_q;
    assign s_axi_bresp    = RESP_OKAY;
    assign s_axi_bvalid   = (state == S_WR_RESP);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            id_q   <= '0;
            addr_q <= '0;
            len_q  <= '0;
            cmd_beats <= '0;
            cmd_left <= '0;
            wrap_low_beats <= '0;
            wrap_pending <= 1'b0;
        end else begin
            unique case (state)
                // ---------------------------------------------------------------
                S_IDLE: begin
                    if (s_axi_arvalid) begin                 // read wins
                        id_q   <= s_axi_arid;
                        addr_q <= s_axi_araddr[31:2];        // byte→dword
                        len_q  <= s_axi_arlen[3:0] + 4'd1;
                        // AXI WRAP8 at dword N is {N..7,0..N-1}.  Translate it
                        // into two incrementing Avalon commands, but do not split
                        // the AXI response: RVALID may pause between commands.
                        if (s_axi_arburst == 2'b10) begin
                            cmd_beats      <= 4'd8 - {1'b0, s_axi_araddr[4:2]};
                            cmd_left       <= 4'd8 - {1'b0, s_axi_araddr[4:2]};
                            wrap_low_beats <= {1'b0, s_axi_araddr[4:2]};
                            wrap_pending   <= (s_axi_araddr[4:2] != 3'd0);
                        end else begin
                            cmd_beats      <= s_axi_arlen[3:0] + 4'd1;
                            cmd_left       <= s_axi_arlen[3:0] + 4'd1;
                            wrap_low_beats <= '0;
                            wrap_pending   <= 1'b0;
                        end
                        state  <= S_RD_CMD;
                    end else if (s_axi_awvalid) begin        // else write
                        id_q   <= s_axi_awid;
                        addr_q <= s_axi_awaddr[31:2];
                        state  <= S_WR_CMD;
                    end
                end
                // ---------------------------------------------------------------
                // Hold avm_read + burstcount until the slave accepts (waitreq low).
                S_RD_CMD: begin
                    if (!avm_waitrequest) state <= S_RD_DATA;
                end
                // Forward each returned dword as an R beat.  A WRAP8 may need a
                // second, low-address Avalon fragment after this command drains.
                S_RD_DATA: begin
                    if (avm_readdatavalid && s_axi_rready) begin
                        if (len_q == 4'd1) begin
                            state <= S_IDLE;                  // AXI RLAST consumed
                        end else if (cmd_left == 4'd1 && wrap_pending) begin
                            addr_q       <= {addr_q[29:3], 3'd0}; // line word 0
                            cmd_beats    <= wrap_low_beats;
                            cmd_left     <= wrap_low_beats;
                            wrap_pending <= 1'b0;
                            state        <= S_RD_CMD;
                        end else begin
                            cmd_left <= cmd_left - 4'd1;
                        end
                        len_q <= len_q - 4'd1;
                    end
                    // NOTE: assumes the AXI master keeps rready high through the
                    // burst (ven_axi_master does). If it can backpressure mid-burst
                    // while readdatavalid is asserted, a skid buffer is needed.
                end
                // ---------------------------------------------------------------
                // Single-beat write: drive avm_write while W data is valid; advance
                // when the slave accepts it.
                S_WR_CMD: begin
                    if (s_axi_wvalid && !avm_waitrequest) state <= S_WR_RESP;
                end
                S_WR_RESP: begin
                    if (s_axi_bready) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef VEN_AXI2AVL_ASSERT
    // Sanity: the Ventium master only ever issues 8-beat (or 1) 4 B reads / 1-beat
    // 4 B writes. Flag anything else loudly so a protocol drift is caught early.
    always_ff @(posedge clk) if (rst_n) begin
        if (s_axi_arvalid && s_axi_arready)
            assert (s_axi_arsize == 3'd2 && (s_axi_arlen == 8'd7 || s_axi_arlen == 8'd0) &&
                    ((s_axi_arburst == 2'b01) || (s_axi_arburst == 2'b10 && s_axi_arlen == 8'd7)))
              else $error("ven_axi2avalon: unexpected AR len=%0d size=%0d burst=%0d",
                          s_axi_arlen, s_axi_arsize, s_axi_arburst);
        if (s_axi_awvalid && s_axi_awready)
            assert (s_axi_awsize == 3'd2 && s_axi_awlen == 8'd0)
              else $error("ven_axi2avalon: unexpected AW len=%0d size=%0d", s_axi_awlen, s_axi_awsize);
    end
`endif

endmodule
