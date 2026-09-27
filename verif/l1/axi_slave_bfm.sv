// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/axi_slave_bfm.sv — a behavioral AXI4 slave standing in for the PS DDR,
// used by tb_l1_axi to verify ventium_l1_axi end-to-end. Byte-addressable backing
// store; honors INCR and 4B-WRAP8 bursts (AR/R) with RLAST, single/burst writes (AW/W/B) with
// WSTRB. A programmable AR->R / AW->B latency (RD_LAT/WR_LAT) models DDR delay so
// the test exercises the L1 MISS STALL (c_ack low for multiple clocks during fill);
// BUBBLE>0 deasserts RVALID for a cycle mid-burst to exercise the stream m_ack
// gating (fw must HOLD on a bubble, not over-advance).
//
// SUBTRACTS REMAP_BASE before indexing: the DUT remaps x86 phys -> the DDR window
// (ddr_addr = REMAP_BASE + phys), so the slave un-remaps to index its backing by
// the x86 phys address the test seeds — a wrong remap reads the wrong word -> FAIL.
//
// All VALID outputs are driven from REGISTERED state, never combinational on the
// master's READY (mirrors the master's own discipline).

module axi_slave_bfm #(
    parameter int          ADDR_W     = 40,
    parameter int          MEM_BYTES  = (1<<20),
    parameter logic [39:0] REMAP_BASE = 40'h00_0000_0000,
    parameter int          RD_LAT     = 4,        // AR accept -> first R beat
    parameter int          WR_LAT     = 3,        // last W -> B
    parameter int          BUBBLE     = 0,        // >0: drop RVALID for 1 cyc mid-burst
    parameter int          STUCK      = 0,        // 1: NEVER respond (exercise the #34 watchdog)
    // REVIEW2 M-08: RLAST fault injection. A compliant slave can never exercise the
    // master's RLAST/beat-count mismatch recovery, so the drain path was unreachable
    // by any existing test.
    //   RLAST_EXTRA > 0 : send N EXTRA beats past arlen, asserting RLAST only on the
    //                     real final one -> a LATE RLAST. The master's count is
    //                     satisfied early, so it must DRAIN these before any new AR
    //                     or they get consumed as the next burst's data.
    //   RLAST_EARLY > 0 : assert RLAST N beats EARLY and end the burst -> the master
    //                     is left waiting for beats that never arrive.
    parameter int          RLAST_EXTRA = 0,
    parameter int          RLAST_EARLY = 0,
    // REVIEW_Aug3 C-01: optional READ-TO-CLEAR device window + AR monitoring, for the
    // L1AXINARROW gate's MMIO model. Addresses are x86-PHYS (post-unmap), matching
    // poke/peek. Default window is EMPTY (LO > HI) -> byte-identical legacy behavior
    // for every existing gate.
    //   RTC: after a read beat whose 4 bytes lie inside [RTC_LO, RTC_HI] is ACCEPTED,
    //        those bytes are zeroed in `mem` (a read-to-clear register). The first
    //        read of a seeded word returns the seed; ANY second read — an illicit
    //        priming burst, a duplicated narrow access, a stale L1 copy's refill —
    //        returns 0, so a duplicated device access is observable in the data.
    //   Monitoring: ar_count = total AR handshakes; burst_beats = the number of R
    //        beats of the most recently COMPLETED burst. The TB checks "exactly one
    //        AR per architectural read" and the response count from these.
    parameter logic [31:0] RTC_LO     = 32'hFFFF_FFFF,
    parameter logic [31:0] RTC_HI     = 32'h0000_0000
) (
    input  logic              clk,
    input  logic              rst_n,
`ifdef AXI_BFM_MON
    // C-01 monitoring outputs (see above). Behind a define so the other seven TBs
    // sharing this BFM (which build with warnings fatal) need no port changes.
    output logic [31:0]       ar_count,
    output logic [31:0]       burst_beats,
`endif
    // write address
    input  logic [3:0]        awid,
    input  logic [ADDR_W-1:0] awaddr,
    input  logic [7:0]        awlen,
    input  logic [2:0]        awsize,
    input  logic [1:0]        awburst,
    input  logic              awvalid,
    output logic              awready,
    // write data
    input  logic [31:0]       wdata,
    input  logic [3:0]        wstrb,
    input  logic              wlast,
    input  logic              wvalid,
    output logic              wready,
    // write response
    output logic [3:0]        bid,
    output logic [1:0]        bresp,
    output logic              bvalid,
    input  logic              bready,
    // read address
    input  logic [3:0]        arid,
    input  logic [ADDR_W-1:0] araddr,
    input  logic [7:0]        arlen,
    input  logic [2:0]        arsize,
    input  logic [1:0]        arburst,
    input  logic              arvalid,
    output logic              arready,
    // read data
    output logic [3:0]        rid,
    output logic [31:0]       rdata,
    output logic [1:0]        rresp,
    output logic              rlast,
    output logic              rvalid,
    input  logic              rready
);

  // test code: wide AXI addresses index a byte array — intentional truncation to
  // the array index width. Suppressed HERE only (the RTL stays strict on WIDTH).
  /* verilator lint_off WIDTHTRUNC */
  /* verilator lint_off WIDTHEXPAND */
  logic [7:0] mem [0:MEM_BYTES-1];

  function automatic logic [ADDR_W-1:0] unmap(input logic [ADDR_W-1:0] axi_addr);
    unmap = axi_addr - REMAP_BASE;            // -> x86 phys index
  endfunction
  // backdoor helpers the test uses to seed / check the backing by x86 phys addr.
  function automatic logic [31:0] peek(input logic [31:0] phys);
    peek = {mem[phys+3], mem[phys+2], mem[phys+1], mem[phys+0]};
  endfunction
  task automatic poke(input logic [31:0] phys, input logic [31:0] d);
    mem[phys+0]=d[7:0]; mem[phys+1]=d[15:8]; mem[phys+2]=d[23:16]; mem[phys+3]=d[31:24];
  endtask

  // ---- READ channel: latch AR, wait RD_LAT, stream arlen+1 beats --------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_BEAT, R_BUB } rstate_e;
  rstate_e          rst_s;
  logic [ADDR_W-1:0] r_addr;  logic [7:0] r_cnt; logic [3:0] r_id; int r_timer;
  logic             bubbled;            // BUBBLE already spent this burst
  logic [31:0]      r_bcnt;             // C-01: accepted beats of the in-flight burst
  logic [1:0]       r_size;             // R2-H01: latched ARSIZE (0=1B, 1=2B, 2=4B)
  logic             r_wrap8;            // cache fill: AXI WRAP, 8 beats x 4 bytes

  assign arready = (rst_s == R_IDLE) && (STUCK==0);   // #34: STUCK -> never ready
`ifdef AXI_BFM_MON
  logic [31:0]      ar_count_q, burst_beats_q;
  assign ar_count    = ar_count_q;
  assign burst_beats = burst_beats_q;
`endif
  always_comb begin
    automatic int unsigned nb;
    rvalid = 1'b0; rdata = 32'd0; rlast = 1'b0; rid = r_id; rresp = 2'b00;
    if (rst_s == R_BEAT) begin
      automatic logic [ADDR_W-1:0] ix = unmap(r_addr);
      rvalid = 1'b1;
      // R2-H01: honor ARSIZE -- the addressed bytes go on their OWN lanes (the AXI
      // narrow-transfer rule); other lanes are zero so the master's lane mask and
      // ven_l1d's OR-merge see exactly the piece. A 4B beat (a fill word or an
      // aligned dword piece) is the full word, as before.
      nb = 32'd1 << r_size;
      for (int b = 0; b < 4; b++)
        if ((32'(b) >= 32'(r_addr[1:0])) && (32'(b) < 32'(r_addr[1:0]) + nb))
          rdata[b*8 +: 8] = mem[ix + 32'(b) - 32'(r_addr[1:0])];
      // M-08 injection: EARLY asserts RLAST while beats remain; EXTRA withholds it
      // until the padded count is exhausted.
      rlast  = (RLAST_EARLY > 0) ? (r_cnt == 8'(RLAST_EARLY))
                                 : (r_cnt == 8'd0);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin rst_s <= R_IDLE; r_addr<=0; r_cnt<=0; r_id<=0; r_timer<=0; bubbled<=0;
`ifdef AXI_BFM_MON
                      ar_count_q<=0; burst_beats_q<=0;
`endif
                      r_size<=2'd2; r_bcnt<=0; r_wrap8<=1'b0; end
    else unique case (rst_s)
      R_IDLE: if (arvalid && STUCK==0) begin
                // M-08: RLAST_EXTRA pads the burst so the slave outlives the master's
                // own beat count -- the LATE-RLAST case.
                r_addr <= araddr; r_cnt <= arlen + 8'(RLAST_EXTRA); r_id <= arid;
                r_size <= arsize[1:0];   // R2-H01
                // The only WRAP shape emitted by ven_axi_master is the AXI-legal
                // cache-line form: 8 beats of 4 bytes.  Fail a TB loudly if a
                // future master changes that contract instead of quietly acting
                // like INCR and masking a data-order bug.
                if ((arburst != 2'b01) && (arburst != 2'b10))
                  $fatal(1, "axi_slave_bfm: unsupported ARBURST %0d", arburst);
                if ((arburst == 2'b10) && ((arlen != 8'd7) || (arsize != 3'd2)))
                  $fatal(1, "axi_slave_bfm: only 4B WRAP8 supported (len=%0d size=%0d)", arlen, arsize);
                r_wrap8 <= (arburst == 2'b10);
                r_timer <= RD_LAT; bubbled <= 1'b0; rst_s <= R_WAIT;
`ifdef AXI_BFM_MON
                // C-01: the AR handshake (arready==1 in R_IDLE) -> one more transaction.
                ar_count_q <= ar_count_q + 32'd1;
`endif
                r_bcnt <= 32'd0;
              end
      R_WAIT: if (r_timer == 0) rst_s <= R_BEAT; else r_timer <= r_timer - 1;
      R_BEAT: if (rready) begin                         // beat accepted (rvalid=1)
                // C-01 READ-TO-CLEAR: this beat's bytes, if inside the device
                // window, are zeroed AFTER being served (rdata above is combinational
                // off mem, so the accepted beat carried the pre-clear value). A second
                // read of the same word — the duplicated access C-01 is about — sees 0.
                // R2-H01: only the beat's own lanes clear (a byte read must not
                // clear its neighbours).
                begin
                  automatic logic [ADDR_W-1:0] ix = unmap(r_addr);
                  automatic int unsigned nb;
                  nb = 32'd1 << r_size;
                  for (int b = 0; b < 4; b++)
                    if ((32'(b) >= 32'(r_addr[1:0])) && (32'(b) < 32'(r_addr[1:0]) + nb)
                        && ((ix + 32'(b) - 32'(r_addr[1:0])) >= ADDR_W'(RTC_LO))
                        && ((ix + 32'(b) - 32'(r_addr[1:0])) <= ADDR_W'(RTC_HI)))
                      mem[ix + 32'(b) - 32'(r_addr[1:0])] <= 8'd0;
                end
                // M-08: with RLAST_EARLY the burst ENDS at the early RLAST -- no
                // further beats, which is what strands a count-driven master.
                if ((RLAST_EARLY > 0) && (r_cnt == 8'(RLAST_EARLY))) begin
                  rst_s <= R_IDLE;
`ifdef AXI_BFM_MON
                  burst_beats_q <= r_bcnt + 32'd1;
`endif
                end
                else if (r_cnt == 8'd0) begin            // RLAST consumed
                  rst_s <= R_IDLE;
`ifdef AXI_BFM_MON
                  burst_beats_q <= r_bcnt + 32'd1;
`endif
                end
                else begin
                  r_cnt <= r_cnt - 8'd1;
                  // A WRAP8 line burst begins at the critical dword and wraps
                  // to line word zero after word seven.  The cache's fill
                  // counter follows this identical circular order.
                  if (r_wrap8 && (r_addr[4:2] == 3'd7))
                    r_addr <= {r_addr[ADDR_W-1:5], 5'd0};
                  else
                    r_addr <= r_addr + 32'd4;
                  r_bcnt <= r_bcnt + 32'd1;
                  // AFTER delivering beat 2, insert ONE genuine rvalid-low bubble
                  // before beat 3 (stresses the stream m_ack gating: fw must hold).
                  if (BUBBLE>0 && !bubbled && r_cnt==8'd5) begin
                    bubbled <= 1'b1; rst_s <= R_BUB;
                  end
                end
              end
      R_BUB:  rst_s <= R_BEAT;                          // one dead cycle (rvalid=0)
      default: rst_s <= R_IDLE;
    endcase
  end

  // ---- WRITE channel: AW + W beats (apply WSTRB), wait WR_LAT, then B ----------
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_WAIT, W_RESP } wstate_e;
  wstate_e          wst_s;
  logic [ADDR_W-1:0] w_addr; logic [3:0] w_id; int w_timer;

  assign awready = (wst_s == W_IDLE) && (STUCK==0);
  assign wready  = (wst_s == W_DATA);
  assign bvalid  = (wst_s == W_RESP);
  assign bid     = w_id;
  assign bresp   = 2'b00;

  always_ff @(posedge clk) begin
    if (!rst_n) begin wst_s <= W_IDLE; w_addr<=0; w_id<=0; w_timer<=0; end
    else unique case (wst_s)
      W_IDLE: if (awvalid && STUCK==0) begin w_addr <= awaddr; w_id <= awid; wst_s <= W_DATA; end
      W_DATA: if (wvalid) begin
                automatic logic [ADDR_W-1:0] ix = unmap(w_addr);
                for (int b=0;b<4;b++) if (wstrb[b]) mem[ix+b] <= wdata[b*8 +: 8];
                if (wlast) begin w_timer <= WR_LAT; wst_s <= W_WAIT; end
                else w_addr <= w_addr + 32'd4;        // (single-beat here; future-proof)
              end
      W_WAIT: if (w_timer == 0) wst_s <= W_RESP; else w_timer <= w_timer - 1;
      W_RESP: if (bready) wst_s <= W_IDLE;
      default: wst_s <= W_IDLE;
    endcase
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, awlen, awsize, awburst, arsize, arburst};
  // verilator lint_on UNUSED
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

endmodule : axi_slave_bfm
