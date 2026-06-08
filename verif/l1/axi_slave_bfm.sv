// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/axi_slave_bfm.sv — a behavioral AXI4 slave standing in for the PS DDR,
// used by tb_l1_axi to verify ventium_l1_axi end-to-end. Byte-addressable backing
// store; honors INCR bursts (AR/R) with RLAST, single/burst writes (AW/W/B) with
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
    parameter int          BUBBLE     = 0         // >0: drop RVALID for 1 cyc mid-burst
) (
    input  logic              clk,
    input  logic              rst_n,
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

  // ---- READ channel: latch AR, wait RD_LAT, stream arlen+1 INCR beats ---------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_BEAT, R_BUB } rstate_e;
  rstate_e          rst_s;
  logic [ADDR_W-1:0] r_addr;  logic [7:0] r_cnt; logic [3:0] r_id; int r_timer;
  logic             bubbled;            // BUBBLE already spent this burst

  assign arready = (rst_s == R_IDLE);
  always_comb begin
    rvalid = 1'b0; rdata = 32'd0; rlast = 1'b0; rid = r_id; rresp = 2'b00;
    if (rst_s == R_BEAT) begin
      automatic logic [ADDR_W-1:0] ix = unmap(r_addr);
      rvalid = 1'b1;
      rdata  = {mem[ix+3], mem[ix+2], mem[ix+1], mem[ix+0]};
      rlast  = (r_cnt == 8'd0);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin rst_s <= R_IDLE; r_addr<=0; r_cnt<=0; r_id<=0; r_timer<=0; bubbled<=0; end
    else unique case (rst_s)
      R_IDLE: if (arvalid) begin
                r_addr <= araddr; r_cnt <= arlen; r_id <= arid;
                r_timer <= RD_LAT; bubbled <= 1'b0; rst_s <= R_WAIT;
              end
      R_WAIT: if (r_timer == 0) rst_s <= R_BEAT; else r_timer <= r_timer - 1;
      R_BEAT: if (rready) begin                         // beat accepted (rvalid=1)
                if (r_cnt == 8'd0) rst_s <= R_IDLE;     // RLAST consumed
                else begin
                  r_cnt <= r_cnt - 8'd1; r_addr <= r_addr + 32'd4;
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

  assign awready = (wst_s == W_IDLE);
  assign wready  = (wst_s == W_DATA);
  assign bvalid  = (wst_s == W_RESP);
  assign bid     = w_id;
  assign bresp   = 2'b00;

  always_ff @(posedge clk) begin
    if (!rst_n) begin wst_s <= W_IDLE; w_addr<=0; w_id<=0; w_timer<=0; end
    else unique case (wst_s)
      W_IDLE: if (awvalid) begin w_addr <= awaddr; w_id <= awid; wst_s <= W_DATA; end
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
