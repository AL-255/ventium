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
//   WRITE = one or two INCR beats, AWLEN=0/1, AWSIZE=2, WSTRB verbatim
// and issues them serially (one outstanding), with registered VALIDs. So this bridge
// handles one Avalon command at a time. VEN_AXI2AVL_BPIPE decouples completed
// Avalon writes from AXI B backpressure with two ordered response slots.
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
    input  logic [7:0]  s_axi_awlen,      // 0=single, 1=fused quadword pair
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
    logic [1:0]   wr_left;       // remaining W beats in current AXI write
`ifdef VEN_AXI2AVL_BPIPE
    // The CPU-facing P54 master has exactly two occupied write slots. Holding
    // at most two completed B responses lets its next ordered AW start while
    // an older B is pending, without acknowledging a write before Avalon took
    // its final data beat. Read AR still waits for the complete B drain.
    logic [3:0] b_id_q [0:1];
    logic b_rp, b_wp;
    logic [1:0] b_count;
    logic b_push, b_pop;
`ifdef VEN_AXI2AVL_WRITE_THROUGH
    // With the P54 master both AW and W are registered and may be presented
    // together. Accept their first Avalon beat on that same edge, while still
    // holding both AXI channels under Avalon backpressure. A missing W takes
    // the original address-first path; a two-beat write retains its second
    // beat in S_WR_CMD. This is not speculative write acknowledgement.
    logic idle_write_offer, idle_write_accept;
    assign idle_write_offer = (state == S_IDLE) && (b_count != 2'd2) &&
                              !s_axi_arvalid && s_axi_awvalid && s_axi_wvalid;
    assign idle_write_accept = idle_write_offer && !avm_waitrequest;
    assign b_push = ((state == S_WR_CMD) && s_axi_wvalid &&
                     !avm_waitrequest && (wr_left == 2'd1)) ||
                    (idle_write_accept && (s_axi_awlen == 8'd0));
`else
    assign b_push = (state == S_WR_CMD) && s_axi_wvalid &&
                    !avm_waitrequest && (wr_left == 2'd1);
`endif
    assign b_pop = s_axi_bvalid && s_axi_bready;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            b_rp <= 1'b0; b_wp <= 1'b0; b_count <= 2'd0;
            b_id_q[0] <= 4'd0; b_id_q[1] <= 4'd0;
        end else begin
            if (b_push) begin
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                b_id_q[b_wp] <= idle_write_accept ? s_axi_awid : id_q;
`else
                b_id_q[b_wp] <= id_q;
`endif
                b_wp <= ~b_wp;
            end
            if (b_pop) b_rp <= ~b_rp;
            unique case ({b_push, b_pop})
                2'b10: b_count <= b_count + 2'd1;
                2'b01: b_count <= b_count - 2'd1;
                default: ;
            endcase
        end
    end
`endif

    // ---- Address-phase acceptance: only when idle, read has priority. -------
`ifdef VEN_AXI2AVL_BPIPE
    assign s_axi_arready = (state == S_IDLE) && (b_count == 2'd0);
    assign s_axi_awready = (state == S_IDLE) && (b_count != 2'd2) &&
                           !s_axi_arvalid
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                           && (!s_axi_wvalid || !s_axi_awvalid || !avm_waitrequest)
`endif
                           ;
`else
    assign s_axi_arready = (state == S_IDLE);
    // Accept the write-address only when idle AND no read is competing this cycle.
    assign s_axi_awready = (state == S_IDLE) && !s_axi_arvalid;
`endif

    // ---- Avalon command outputs (registered address, combinational strobes) -
`ifdef VEN_AXI2AVL_WRITE_THROUGH
    assign avm_address    = idle_write_offer ? s_axi_awaddr[31:2] : addr_q;
`else
    assign avm_address    = addr_q;
`endif
    assign avm_burstcount = (state == S_RD_CMD) ? cmd_beats : 4'd1;
    assign avm_read       = (state == S_RD_CMD);
    assign avm_write      = ((state == S_WR_CMD) && s_axi_wvalid)
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                            || idle_write_offer
`endif
                            ;

    // Avalon accepts one dword at a time; hold each AXI W until that write
    // command is accepted, then advance the dword address for burst beat 2.
    assign avm_writedata  = s_axi_wdata;
    assign avm_byteenable = s_axi_wstrb;
    assign s_axi_wready   = ((state == S_WR_CMD)
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                             || idle_write_offer
`endif
                             ) && !avm_waitrequest;

    // Read-data (R) channel
    assign s_axi_rdata    = avm_readdata;
    assign s_axi_rresp    = RESP_OKAY;
    assign s_axi_rid      = id_q;
    assign s_axi_rvalid   = (state == S_RD_DATA) && avm_readdatavalid;
    assign s_axi_rlast    = (state == S_RD_DATA) && avm_readdatavalid && (len_q == 4'd1);

    // Write-response (B) channel
`ifdef VEN_AXI2AVL_BPIPE
    assign s_axi_bid      = b_id_q[b_rp];
    assign s_axi_bvalid   = (b_count != 2'd0);
`else
    assign s_axi_bid      = id_q;
    assign s_axi_bresp    = RESP_OKAY;
    assign s_axi_bvalid   = (state == S_WR_RESP);
`endif
`ifdef VEN_AXI2AVL_BPIPE
    assign s_axi_bresp    = RESP_OKAY;
`endif

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
            wr_left <= '0;
        end else begin
            unique case (state)
                // ---------------------------------------------------------------
                S_IDLE: begin
                    if (s_axi_arvalid && s_axi_arready) begin // read wins
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
                    end else if (s_axi_awvalid && s_axi_awready) begin // else write
                        id_q   <= s_axi_awid;
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                        if (idle_write_accept) begin
                            if (s_axi_awlen == 8'd0) begin
                                wr_left <= 2'd0;
                                state <= S_IDLE;
                            end else begin
                                addr_q <= s_axi_awaddr[31:2] + 30'd1;
                                wr_left <= 2'd1;
                                state <= S_WR_CMD;
                            end
                        end else begin
`endif
                            addr_q <= s_axi_awaddr[31:2];
                            wr_left <= {1'b0, s_axi_awlen[0]} + 2'd1;
                            state <= S_WR_CMD;
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                        end
`endif
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
                // One Avalon write per AXI W beat.  Return ONE B only after
                // WLAST (not after the first beat of a fused pair).
                S_WR_CMD: begin
                    if (s_axi_wvalid && !avm_waitrequest) begin
                        wr_left <= wr_left - 2'd1;
`ifdef VEN_AXI2AVL_BPIPE
                        if (wr_left == 2'd1) state <= S_IDLE;
`else
                        if (wr_left == 2'd1) state <= S_WR_RESP;
`endif
                        else addr_q <= addr_q + 30'd1;
                    end
                end
                S_WR_RESP: begin
                    if (s_axi_bready) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef VEN_AXI2AVL_ASSERT
    // Sanity: the Ventium master only ever issues 8-beat (or 1) 4 B reads,
    // and 1- or 2-beat 4 B writes. Flag protocol drift loudly.
    always_ff @(posedge clk) if (rst_n) begin
`ifdef VEN_AXI2AVL_WRITE_THROUGH
        assert (!(idle_write_accept && (!s_axi_awready || !s_axi_wready ||
                                        !avm_write || avm_address != s_axi_awaddr[31:2])))
          else $error("ven_axi2avalon: direct AW/W/Avalon handshake disagreed");
`endif
`ifdef VEN_AXI2AVL_BPIPE
        assert (!(b_push && b_count == 2'd2 && !b_pop))
          else $error("ven_axi2avalon: completed write overflowed B response queue");
        assert (!(b_pop && b_count == 2'd0))
          else $error("ven_axi2avalon: B response underflow");
`endif
        if (s_axi_arvalid && s_axi_arready)
            assert (s_axi_arsize == 3'd2 && (s_axi_arlen == 8'd7 || s_axi_arlen == 8'd0) &&
                    ((s_axi_arburst == 2'b01) || (s_axi_arburst == 2'b10 && s_axi_arlen == 8'd7)))
              else $error("ven_axi2avalon: unexpected AR len=%0d size=%0d burst=%0d",
                          s_axi_arlen, s_axi_arsize, s_axi_arburst);
        if (s_axi_awvalid && s_axi_awready)
            assert (s_axi_awsize == 3'd2 && s_axi_awlen <= 8'd1 &&
                    s_axi_awburst == 2'b01)
              else $error("ven_axi2avalon: unexpected AW len=%0d size=%0d", s_axi_awlen, s_axi_awsize);
        if (s_axi_wvalid && s_axi_wready)
            assert (s_axi_wlast ==
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                    (idle_write_accept ? (s_axi_awlen == 8'd0) :
`endif
                    (wr_left == 2'd1)
`ifdef VEN_AXI2AVL_WRITE_THROUGH
                    )
`endif
                    )
              else $error("ven_axi2avalon: wrong WLAST left=%0d last=%b", wr_left, s_axi_wlast);
    end
`endif

endmodule
