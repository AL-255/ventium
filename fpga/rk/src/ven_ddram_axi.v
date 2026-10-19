// ven_ddram_axi.v — bridge the ao486_MiSTer `system` DDRAM_* master (64-bit MiSTer
// Avalon-burst) to a 64-bit AXI4 master feeding the PS S_AXI_HP0 (guest RAM in PS-DDR).
//
// DDRAM protocol (authoritative: ao486-sim ddr_service()):
//   * DDRAM_ADDR is a 64-bit-WORD address (25b => 256 MB). AXI byte addr = ADDR<<3 + MEM_BASE.
//   * READ  : on the RISING edge of DDRAM_RD, latch ADDR+BURSTCNT; return BURSTCNT words,
//             each pulsed on DDRAM_DOUT + DDRAM_DOUT_READY.
//   * WRITE : l2_cache is write-through, so only single-beat writes occur (ram_burstcnt<=1).
// VERIFIED (tb_ddram_axi.cpp) for 100% of real DDRAM traffic. dbg_st exposes the FSM state
// for on-hardware mem-path observability (read back through ven_mgmt_axil DBG @ 0x60).
`default_nettype wire
module ven_ddram_axi #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_ID_W   = 4,
    // Guest-physical 0 lands at this AXI byte address. 0 for cosim/testbench (byte-identical);
    // on FPGA this is the reserved PS-DDR carveout base so guest RAM does not overlap Linux RAM.
    parameter [AXI_ADDR_W-1:0] MEM_BASE = 0
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- DDRAM slave (faces `system`'s DDRAM_* master) ----
    output wire         DDRAM_BUSY,
    input  wire [7:0]   DDRAM_BURSTCNT,
    input  wire [24:0]  DDRAM_ADDR,       // 64-bit-word address
    output reg  [63:0]  DDRAM_DOUT,
    output reg          DDRAM_DOUT_READY,
    input  wire         DDRAM_RD,
    input  wire [63:0]  DDRAM_DIN,
    input  wire [7:0]   DDRAM_BE,
    input  wire         DDRAM_WE,

    // ---- AXI4 master (64-bit) to the SmartConnect -> HP0 ----
    output reg  [AXI_ID_W-1:0]   m_axi_awid,
    output reg  [AXI_ADDR_W-1:0] m_axi_awaddr,
    output reg  [7:0]            m_axi_awlen,
    output wire [2:0]            m_axi_awsize,
    output wire [1:0]            m_axi_awburst,
    output reg                   m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [63:0]           m_axi_wdata,
    output wire [7:0]            m_axi_wstrb,
    output wire                  m_axi_wlast,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    output reg  [AXI_ID_W-1:0]   m_axi_arid,
    output reg  [AXI_ADDR_W-1:0] m_axi_araddr,
    output reg  [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output reg                   m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [63:0]           m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,
    output wire [2:0]            dbg_st          // FSM state, for hardware mem-path observability
);
    assign m_axi_awsize  = 3'b011;   // 8 bytes/beat
    assign m_axi_arsize  = 3'b011;
    assign m_axi_awburst = 2'b01;    // INCR
    assign m_axi_arburst = 2'b01;
    assign m_axi_bready  = 1'b1;

    localparam [2:0] S_IDLE=3'd0, S_AR=3'd1, S_R=3'd2, S_W=3'd3, S_B=3'd4;
    reg [2:0]  st;
    reg [7:0]  wbeats;
    assign dbg_st = st;

    reg rd_q;
    always @(posedge clk) rd_q <= DDRAM_RD;
    wire rd_rise = DDRAM_RD & ~rd_q;

    reg [63:0] wd; reg [7:0] ws; reg wl;
    assign m_axi_wdata  = wd;
    assign m_axi_wstrb  = ws;
    assign m_axi_wvalid = m_wv;
    assign m_axi_wlast  = wl;
    reg m_wv;
    // AXI AW and W are independent channels.  In particular, an interconnect
    // may accept W before AW.  A write must remain in S_W until both channels
    // have individually handshaken; entering S_B after W alone leaves AWVALID
    // asserted, which can duplicate an address command while B is delayed.
    wire aw_hs = m_axi_awvalid && m_axi_awready;
    wire w_hs  = m_wv && m_axi_wready;
    // Fold a handshake on this edge into the completion test.  For a multi-beat
    // transfer `wl` denotes the beat presented on this edge, so only its final
    // W handshake may complete the data channel.
    wire write_cmd_done = (!m_axi_awvalid || aw_hs) &&
                          (!m_wv || (w_hs && wl));
    assign m_axi_rready = (st == S_R);
    // VEN FIX (Win95 relocation, build #21): read-after-write barrier. Core-halt proved DDR holds the
    // CORRECT relocation source at the copy instant, yet the DCACHE served STALE bytes -> a DCACHE fill
    // issued right after the disk-load store read the same line before the store COMMITTED (the store's
    // BVALID fires before the PS-DDR write actually lands), caching stale data. Hold READs off for a few
    // cycles after each write completes so the write commits before any fill reads it. A read requested
    // during the barrier is latched (rd_pend + address) so a held DDRAM_RD is never dropped.
    reg [7:0]  wr_bar;  reg rd_pend;  reg [27:0] rd_addr_lat;  reg [7:0] rd_burst_lat;
    // build #31 DOUBLE-READ: the PS S_AXI_HP async DDR read FIFO returns the PREVIOUS read's burst (proven:
    // reads of 0x700 return recently-read foreign lines "QUAKE"/"WIN95" while the ARM uncached view = MZ,
    // and ven_ddram_axi issues the CORRECT araddr). Off-by-one stale FIFO -> issue every read TWICE at the
    // same address: the FIRST (priming) burst returns the stale prior data (DISCARD it); the SECOND burst
    // returns THIS address's data (the first read's own result), which we deliver as DDRAM_DOUT.
    reg rd_primed;
    assign DDRAM_BUSY = (st != S_IDLE) || (wr_bar != 8'd0) || rd_pend;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            m_axi_awvalid <= 1'b0; m_axi_arvalid <= 1'b0; m_wv <= 1'b0; wl <= 1'b0;
            DDRAM_DOUT_READY <= 1'b0; m_axi_awid <= 0; m_axi_arid <= 0; wbeats <= 8'd0;
            wr_bar <= 8'd0; rd_pend <= 1'b0; rd_addr_lat <= 28'd0; rd_burst_lat <= 8'd0; rd_primed <= 1'b0;
        end else begin
            DDRAM_DOUT_READY <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (wr_bar != 8'd0) wr_bar <= wr_bar - 8'd1;   // read-after-write barrier countdown
                    // Priority: a READ starts only when the barrier is clear (write committed); WRITES
                    // always proceed (each re-arms the barrier); a read requested DURING the barrier is
                    // latched (rd_pend + address) so it fires the moment the barrier clears.
                    if ((wr_bar == 8'd0) && (rd_pend || rd_rise)) begin
                        m_axi_araddr  <= {{(AXI_ADDR_W-28){1'b0}}, (rd_pend ? rd_addr_lat : DDRAM_ADDR), 3'b000} + MEM_BASE;
                        m_axi_arlen   <= ((rd_pend ? rd_burst_lat : DDRAM_BURSTCNT)==8'd0) ? 8'd0 : ((rd_pend ? rd_burst_lat : DDRAM_BURSTCNT) - 8'd1);
                        m_axi_arvalid <= 1'b1;
                        rd_pend       <= 1'b0;
                        rd_primed     <= 1'b0;   // this AR is the PRIMING (discard) read; the re-issue is the real one
                        st <= S_AR;
                    end else if (DDRAM_WE) begin
                        m_axi_awaddr  <= {{(AXI_ADDR_W-28){1'b0}}, DDRAM_ADDR, 3'b000} + MEM_BASE;
                        m_axi_awlen   <= (DDRAM_BURSTCNT==0) ? 8'd0 : (DDRAM_BURSTCNT - 8'd1);
                        m_axi_awvalid <= 1'b1;
                        wbeats        <= (DDRAM_BURSTCNT==0) ? 8'd1 : DDRAM_BURSTCNT;
                        wd <= DDRAM_DIN; ws <= DDRAM_BE; m_wv <= 1'b1;
                        wl <= (DDRAM_BURSTCNT <= 1);
                        st <= S_W;
                    end else if (rd_rise) begin  // read arrived during the barrier: latch it
                        rd_pend <= 1'b1; rd_addr_lat <= DDRAM_ADDR; rd_burst_lat <= DDRAM_BURSTCNT;
                    end
                end
                S_AR: if (m_axi_arready) begin m_axi_arvalid <= 1'b0; st <= S_R; end
                S_R:  if (m_axi_rvalid) begin
                        if (rd_primed) begin
                            // SECOND (real) read: deliver the data (= THIS address's content).
                            DDRAM_DOUT       <= m_axi_rdata;
                            DDRAM_DOUT_READY <= 1'b1;
                            if (m_axi_rlast) st <= S_IDLE;
                        end else if (m_axi_rlast) begin
                            // FIRST (priming) read done: its beats were the STALE prior data (discarded, no
                            // DDRAM_DOUT_READY). Re-issue the SAME burst (araddr/arlen preserved) as the real read.
                            rd_primed     <= 1'b1;
                            m_axi_arvalid <= 1'b1;
                            st <= S_AR;
                        end
                      end
                S_W: begin
                    if (aw_hs) m_axi_awvalid <= 1'b0;
                    if (w_hs) begin
                        if (wl) begin m_wv <= 1'b0; end
                        else begin wbeats <= wbeats - 8'd1; wd <= DDRAM_DIN; ws <= DDRAM_BE;
                                   wl <= (wbeats == 8'd2); end
                    end
                    // Do not let W-first acceptance advance to B while AW is
                    // still outstanding.  Conversely, AW-first waits here
                    // for the final W.  Both VALID signals remain asserted
                    // until their own handshake, as AXI requires.
                    if (write_cmd_done) st <= S_B;
                end
                S_B: if (m_axi_bvalid) begin st <= S_IDLE; wr_bar <= 8'd0; end  // build #28: barrier DISABLED (wr_bar stays 0 -> reads never latched, fire immediately = original behavior). Build #27 showed the barrier+L2-disable+golden combo is the read-response mis-sync source; revert to the proven path.
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
