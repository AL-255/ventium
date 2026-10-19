// rk_ao486_system_pl.v — the PL-side integration: ao486_MiSTer `system` (Ventium core) + the two
// VERIFIED shims (ven_ddram_axi guest RAM, ven_mgmt_axil HPS control) + status LEDs. This is the
// fabric block the BD wraps (PS pl_clk0/resetn0, M_AXI to HP0, S_AXIL from HPM0, pl_ps_irq0).
`default_nettype wire
// module-ref interface inference: each AXI port carries (* X_INTERFACE_INFO *) (module-ref does
// not auto-infer from naming). DONT_TOUCH: PS-only design with no external PL I/O except the LEDs;
// without it synth sweeps the AXI-only PL logic (see README §1.5.2). Both are inert to Verilator.
(* DONT_TOUCH = "yes" *)
module rk_ao486_system_pl #(
    parameter CLK_HZ   = 32'd3_125_000,   // actual core/SoC clock; overridden by the BD profile
    parameter [31:0] MEM_BASE = 32'h6000_0000  // guest RAM carveout base (inside the board CMA region)
)(
    // No FREQ_HZ on clk: let soc/clk inherit pl_clk0's actual frequency (README §1.5.2).
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIL:M_AXI, ASSOCIATED_RESET resetn" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         resetn,

    // ---- AXI4-Lite slave (from PS M_AXI_HPM0_FPD) : control/mgmt/BIOS/disk ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWADDR" *)  input  wire [15:0]  s_axil_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWVALID" *) input  wire s_axil_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL AWREADY" *) output wire s_axil_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WDATA" *)   input  wire [31:0]  s_axil_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WSTRB" *)   input  wire [3:0]   s_axil_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WVALID" *)  input  wire s_axil_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL WREADY" *)  output wire s_axil_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BRESP" *)   output wire [1:0]   s_axil_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BVALID" *)  output wire s_axil_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL BREADY" *)  input  wire s_axil_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARADDR" *)  input  wire [15:0]  s_axil_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARVALID" *) input  wire s_axil_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL ARREADY" *) output wire s_axil_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RDATA" *)   output wire [31:0]  s_axil_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RRESP" *)   output wire [1:0]   s_axil_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RVALID" *)  output wire s_axil_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXIL RREADY" *)  input  wire s_axil_rready,

    // ---- AXI4 master (64-bit) to guest RAM (PS S_AXI_HP0_FPD) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)     output wire [3:0]   m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)   output wire [31:0]  m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)    output wire [7:0]   m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)   output wire [2:0]   m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)  output wire [1:0]   m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)  output wire m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)  input  wire m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)    output wire [63:0]  m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)    output wire [7:0]   m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)    output wire m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)   output wire m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)   input  wire m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)    input  wire [1:0]   m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)   input  wire m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)   output wire m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)     output wire [3:0]   m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)   output wire [31:0]  m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)    output wire [7:0]   m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)   output wire [2:0]   m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)  output wire [1:0]   m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)  output wire m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)  input  wire m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)    input  wire [63:0]  m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)    input  wire [1:0]   m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)    input  wire m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)   input  wire m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)   output wire m_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 IRQ INTERRUPT" *)
    output wire         pl_ps_irq0,
    output wire pll_safe,
    output wire [3:0]   led               // status LEDs + structural anchor (README §1.5.2)
);
    wire rst = ~resetn;

    // ---- shim <-> system nets ----
    wire [15:0] mgmt_address, mgmt_readdata, mgmt_writedata;
    wire        mgmt_read, mgmt_write;
    wire [1:0]  fdd_request;  wire [2:0] ide0_request, ide1_request;
    wire        core_reset_n; wire cpu_hung = 1'b0;

    // DDRAM master <-> AXI
    wire        DDRAM_BUSY; wire [7:0] DDRAM_BURSTCNT; wire [24:0] DDRAM_ADDR;
    wire [63:0] DDRAM_DOUT; wire DDRAM_DOUT_READY, DDRAM_RD; wire [63:0] DDRAM_DIN; wire [7:0] DDRAM_BE; wire DDRAM_WE;
    wire [2:0]  dbg_st;

    // ---- mem-path observability: counters + live handshake, read back via ven_mgmt_axil DBG @0x60.
    // Answers "does the core issue fetches, and where does the HP0 read stall?" without a JTAG ILA.
    reg [7:0] cnt_rd, cnt_ar, cnt_r; reg ddram_rd_q;
    // task #53: the cnt_* above SATURATE at 0xFF, which is why every DBG dump has read
    // "cnt_rd=255 cnt_ar=255 cnt_r=255" — they are useless for throughput. These are the same
    // events counted FREE-RUNNING at 32 bits, exposed in the perf bank (0x170/0x180/0x190).
    // With perf_cyc (0x100/0x110) over any interval:
    //   d(beats)/d(cyc)      -> the TRUE per-beat read cost, MEASURED not inferred (the 17.1
    //                           cyc/beat figure is currently only an inference from CPI matching)
    //   d(beats)/d(ar)       -> should be 8; confirms burst coalescing works on HARDWARE, and
    //                           SEPARATES "bursts slow to start" (smartconnect/HP0) from "beats
    //                           slow within a burst" (ven_axi_cdc response drain). Different fixes.
    //   d(b_hs)              -> confirms on HARDWARE that the write path is off the critical path;
    //                           so far that is only established in simulation (UPDATE 240).
    // NOTE ar_hs counts the rd_primed PRIMING burst too, so beats/ar ~= 8 with the double fill
    // issuing two ARs per line — i.e. ar_hs is ~2x the line-fill count, by design.
    reg [31:0] p_rd_beats, p_ar_hs, p_b_hs;
    // Passive profiler for the outer (45 MHz) AXI boundary.  It observes only
    // accepted handshakes and drives the otherwise-invalid 0x1A0/0x1B0
    // diagnostics; it cannot affect the bridge or any guest-visible state.
    wire [31:0] p_rd_busy_cyc, p_rd_firstwait_cyc;
    ven_axi_read_profiler u_axi_read_profiler (
        .clk(clk), .rst(rst),
        .ar_handshake(m_axi_arvalid & m_axi_arready),
        .r_handshake(m_axi_rvalid & m_axi_rready), .r_last(m_axi_rlast),
        .busy_cycles(p_rd_busy_cyc), .first_wait_cycles(p_rd_firstwait_cyc)
    );
    always @(posedge clk) begin
        if (rst) begin p_rd_beats<=32'd0; p_ar_hs<=32'd0; p_b_hs<=32'd0; end
        else begin
            if (m_axi_rvalid  & m_axi_rready)  p_rd_beats <= p_rd_beats + 32'd1;
            if (m_axi_arvalid & m_axi_arready) p_ar_hs    <= p_ar_hs    + 32'd1;
            if (m_axi_bvalid  & m_axi_bready)  p_b_hs     <= p_b_hs     + 32'd1;
        end
    end
    always @(posedge clk) begin
        if (rst) begin cnt_rd<=0; cnt_ar<=0; cnt_r<=0; ddram_rd_q<=0; end
        else begin
            ddram_rd_q <= DDRAM_RD;
            if (DDRAM_RD & ~ddram_rd_q)        cnt_rd <= cnt_rd + (cnt_rd!=8'hFF);  // fetch/read requests
            if (m_axi_arvalid & m_axi_arready) cnt_ar <= cnt_ar + (cnt_ar!=8'hFF);  // AR accepted by HP0
            if (m_axi_rvalid  & m_axi_rready)  cnt_r  <= cnt_r  + (cnt_r !=8'hFF);  // R data returned
        end
    end
    wire [31:0] dbg_word = { DDRAM_RD, DDRAM_BUSY, m_axi_rvalid, m_axi_arready, m_axi_arvalid,
                             dbg_st, cnt_r, cnt_ar, cnt_rd };
    // last fetch/read physical address (guest byte addr = dbg_araddr - MEM_BASE) -> DBG2 @ 0x70.
    // Shows WHERE the core stopped issuing new fetches (= the cached-loop region if it is spinning).
    reg [31:0] last_araddr;
    always @(posedge clk) begin
        if (rst) last_araddr <= 32'd0;
        else if (m_axi_arvalid & m_axi_arready) last_araddr <= m_axi_araddr;
    end
    wire [31:0] dbg_word2 = last_araddr;

    // build #29 DDRAM-BOUNDARY read tap: isolate whether ven_ddram_axi RETURNS correct data (vs the L2/
    // upstream corrupting it). Latch the read word-address at DDRAM_RD rise; count 64-bit beats on
    // DDRAM_DOUT_READY. Overrides d_rd_* below so the dbg ring shows DDRAM_DOUT for the x86 0x700 line
    // (64b word addr 0xe0-0xe3 => [24:2]==0x38). If DDRAM_DOUT here = MZ 4d5a -> ven_ddram_axi is correct
    // and the corruption is UPSTREAM (L2/avm). If = QUAKE/WIN95 -> ven_ddram_axi/HP0 returns wrong data.
    reg [24:0] ddr_ra_lat; reg [2:0] ddr_dbeat;
    always @(posedge clk) begin
        if (rst) begin ddr_ra_lat <= 25'd0; ddr_dbeat <= 3'd0; end
        else if (DDRAM_RD & ~ddram_rd_q) begin ddr_ra_lat <= DDRAM_ADDR; ddr_dbeat <= 3'd0; end
        else if (DDRAM_DOUT_READY)             ddr_dbeat <= ddr_dbeat + 3'd1;
    end

    // ---- ven_soc_dbg forensic block: PC ring + read-beat ring + freeze snapshot ----------------
    // Fed by the Ventium core's packed debug bundle (routed out through system.v/ven_ao486_shim);
    // the PS reads it back over ven_mgmt_axil (0x80..0xF0) to see the instruction trail + AXI fill
    // words INTO a derail without a sim. Layout must match ven_ao486_shim's pack.
    // The VGA recorder is intentionally outside that bundle: it samples the
    // final scan-out and cannot influence the CPU/VGA memory interfaces.
    wire video_ce, video_blank_n, video_hsync, video_vsync;
    wire [7:0] video_r, video_g, video_b;
    wire cap_arm, cap_rd_en, cap_frame_ready, cap_capture_active, cap_frame_overrun;
    wire [16:0] cap_rd_addr;
    wire [31:0] cap_rd_data, cap_frame_sequence;
    wire [63:0] cap_frame_cycle;
    wire [11:0] cap_frame_width, cap_frame_height;
    wire [19:0] cap_frame_pixels;
    // Hosted keyboard-device transport.  These are physical PS/2 wire levels
    // (1=release); the injector and 8042 are wire-ANDed exactly as two
    // open-drain devices would be.  There is no guest-memory shortcut.
    wire [7:0] kbd_inject_data;
    wire kbd_inject_valid, kbd_inject_ready, kbd_inject_busy;
    wire ps2_kbclk_host, ps2_kbdat_host, ps2_kbclk_dev, ps2_kbdat_dev;
    wire ps2_kbclk_in = ps2_kbclk_host & ps2_kbclk_dev;
    wire ps2_kbdat_in = ps2_kbdat_host & ps2_kbdat_dev;
    // Kept in the guest reset domain below, after the forensic reset source is
    // declared.  A queued device byte must not leak across a guest reset.
    wire soc_reset;
    wire mouse_csr_write;
    wire [3:0] mouse_csr_waddr, mouse_csr_wstrb, mouse_csr_raddr;
    wire [31:0] mouse_csr_wdata, mouse_csr_rdata;
    wire mouse_tx_valid, mouse_tx_ready, mouse_tx_done, mouse_tx_aborted;
    wire mouse_rx_valid, mouse_rx_ready, mouse_rx_aborted;
    wire [7:0] mouse_tx_data, mouse_rx_data;
    wire [1:0] mouse_rx_error;
    wire ps2_mouseclk_host, ps2_mousedat_host, ps2_mouseclk_dev, ps2_mousedat_dev;
    wire [290:0] cpu_dbg_bus; wire [127:0] cpu_dbg_cmp;
    wire         d_inta          = cpu_dbg_bus[0];
    wire         d_retire_valid  = cpu_dbg_bus[1];
    wire [31:0]  d_eip           = cpu_dbg_bus[33:2];
    wire [15:0]  d_cs            = cpu_dbg_bus[49:34];
    wire [31:0]  d_esp           = cpu_dbg_bus[81:50];
    wire [31:0]  d_eflags        = cpu_dbg_bus[113:82];
    wire [5:0]   d_state         = cpu_dbg_bus[119:114];
    wire [7:0]   d_int_vec       = cpu_dbg_bus[127:120];
    wire [31:0]  d_fault_pc      = cpu_dbg_bus[159:128];
    wire [31:0]  d_cr0           = cpu_dbg_bus[191:160];
    // build #30: d_rd_* back to the CORE-SIDE tap (from cpu_dbg_bus, driven by ventium_l1_axi).
    wire         d_rd_valid      = cpu_dbg_bus[192];
    wire [31:0]  d_rd_addr       = cpu_dbg_bus[224:193];
    wire [31:0]  d_rd_data       = cpu_dbg_bus[256:225];
    wire         d_cmp_freeze    = cpu_dbg_bus[257];
    wire         d_halted        = cpu_dbg_bus[258];
    wire [31:0]  d_arch_data     = cpu_dbg_bus[290:259];
    // VEN DIAG: address-match freeze — pulse when the FreeDOS relocation copy issues the AW for guest
    // 0x80240 (AXI 0x60080240), inside the code->table divergence region (~0x801c3). OR'd into the ring
    // freeze so the 128-deep WRITE ring stops holding 0x801c0..0x80240 (the writes AT the divergence)
    // instead of evicting them past the copy. First AW to 0x80240 wins (0x80240=512KB+576B is unused by
    // BIOS/bootloader pre-relocation, so this is the copy's own write).
    // VEN DIAG (build #11): freeze the ring on the CORE READ-SERVE of guest 0x940 (a divergence-source
    // load: dst 0x80240 = src[0x940], DI==SI, inside the code->table region). d_rd_addr[27:0]=core_addr,
    // [31:28]=serve state. Ring then holds the DIVERGENCE source-load serves 0x900..0x93c -> shows whether
    // the L1D serves them CODE (=> store handoff) or TABLE (=> DCACHE serve staleness). The prior AW-0x80240
    // freeze latched on the self-referential STUB stall (0x961) and evicted the real divergence loads.
    // VEN DIAG (build #12): freeze on the CORE READ-SERVE of guest 0xb00 — an address ONLY the REP CS
    // MOVSB copy reads (SI=0x400 -> dst 0x80400, in the 0x80200..0x80440 table region). The init loop
    // only re-reads 0x920..0x943, so 0xb00's first serve is the COPY's own data load. Ring then holds the
    // REP's divergence loads 0xac0..0xb00 -> definitively CODE (store handoff) vs TABLE (L1D serve stale).
    // build #14: DISABLE the address-match freeze; use the natural stall-freeze at the 0x3a0 hang so the
    // write-ring (filtered to 0xb00..0xb3f writes) holds the KERNEL-LOAD stores to 0xb00 + their hit-state.
    // build #30: freeze the ring on the copy's FIRST dest write (HP0 AW to guest 0x80000 = 0x60080000),
    // catching the copy at its START so the core-side load/store ring holds the FIRST-byte load(0x700)+
    // store(0x80000) PAIR (not evicted). Resolves store-vs-load-vs-address at the exact corruption point.
    reg wr_frozen_q;
    wire d_wr_hit = m_axi_awvalid & m_axi_awready & (m_axi_awaddr == 32'h6008_0000);
    always @(posedge clk) begin
        if (rst) wr_frozen_q <= 1'b0;
        else if (d_wr_hit) wr_frozen_q <= 1'b1;
    end
    wire         d_wr_freeze     = 1'b0;  // build #33: disabled — BOOT TEST of the segment-override fix (dseg=q_seg)

    // control (from ven_mgmt_axil) + readback (to ven_mgmt_axil)
    wire [6:0]  dbg_trace_idx; wire dbg_clear, dbg_ext_freeze;  // 7b idx reaches all DEPTH=128 entries
    wire [31:0] dbg_freeze_thresh, dbg_cmp_cfg, dbg_cmp_range;
    wire        dbg_halt_req, dbg_step, dbg_bp_en, dbg_bp_clr;
    wire [31:0] dbg_bp_addr;
    wire [6:0]  dbg_arch_sel;
    wire ddr_posted_drained, ddr_posted_fault;
    // Observability only: CPU reset and real outer AXI drain interlock.
    assign pll_safe = ~core_reset_n & ddr_posted_drained & ~ddr_posted_fault;
    // Keep [63] exactly as the historical comparator-range bit: the BDA
    // coherence-invalidation pulse below intentionally keys from that bit.
    // The execution debugger occupies only the new high control bits.
`ifdef VEN_DDR_POSTED
    // Hardware-only drain capability/status; PS controls cannot override it.
    assign cpu_dbg_cmp = {18'd0, ddr_posted_fault, 1'b1, ddr_posted_drained,
                          dbg_arch_sel, dbg_bp_clr, dbg_bp_addr,
                          dbg_bp_en, dbg_step, dbg_halt_req, dbg_cmp_range, dbg_cmp_cfg};
`else
    assign cpu_dbg_cmp = {21'd0, dbg_arch_sel, dbg_bp_clr, dbg_bp_addr,
                          dbg_bp_en, dbg_step, dbg_halt_req, dbg_cmp_range, dbg_cmp_cfg};
`endif
    wire [31:0] dbg_last_eip, dbg_frozen_eip, dbg_frozen_ctx_eip, dbg_trace_pc, dbg_trace_aux, dbg_rd_ring_addr, dbg_rd_ring_data, dbg_rd_ring_data_hi, dbg_perf_stall;
    wire [15:0] dbg_frozen_cs;
    wire [31:0] dbg_frozen_esp, dbg_frozen_eflags, dbg_frozen_fault_pc, dbg_frozen_cr0;
    // PERF (task #24): ven_soc_dbg already counts these; they were left unconnected so IPC was
    // unmeasurable on hardware. Wire them to ven_mgmt_axil reads 0x04/0x08/0x0C/0x14/0x18/0x1C.
    wire [63:0] dbg_perf_cyc, dbg_perf_retired;
    wire [31:0] dbg_perf_io, dbg_perf_irq;
    wire [31:0] dbg_st_pipe, dbg_st_walk, dbg_st_fetch, dbg_st_other;  // task #54 state bins
    wire        dbg_frozen; wire [5:0] dbg_frozen_state; wire [7:0] dbg_frozen_vec; wire [7:0] dbg_trace_count;
    assign soc_reset = rst | ~core_reset_n | dbg_frozen;

    // rd-beat ring taps the M_AXI READ channel (the HP0 boundary) so it shows the exact 64-bit
    // fill words the core fetches -> a corrupted line fill (correct DDR data, wrong HP0 return) is
    // visible directly. mbeat_addr tracks the burst's per-beat byte address (INCR, 8B/beat).
    // VEN DIAG: repurposed to tap the M_AXI WRITE channel so the "rd-beat" ring shows the exact
    // 64-bit words the core STORES to DDR (HP0) — confirms whether REP INSW's microcoded store
    // lands the identify in memory (to what addr, what data). Revert aw/w->ar/r for read forensics.
    reg [31:0] mbeat_addr;
    always @(posedge clk) begin
        if (rst)                                mbeat_addr <= 32'd0;
        else if (m_axi_awvalid & m_axi_awready) mbeat_addr <= m_axi_awaddr;          // write burst base
        else if (m_axi_wvalid  & m_axi_wready)  mbeat_addr <= mbeat_addr + 32'd8;     // next write beat
    end
    // READ-beat forensics: track the READ burst per-beat address (INCR, 8B/beat) so the ring can
    // capture the source-read fill sequence during the FreeDOS REP MOVSB relocation — proves whether
    // a fill delivers WRONG DATA for a CORRECT address (memory-path race) at cs=0070:0x261.
    reg [31:0] rbeat_addr;
    always @(posedge clk) begin
        if (rst)                                rbeat_addr <= 32'd0;
        else if (m_axi_arvalid & m_axi_arready) rbeat_addr <= m_axi_araddr;          // read burst base
        else if (m_axi_rvalid  & m_axi_rready)  rbeat_addr <= rbeat_addr + 32'd8;     // next read beat
    end

    // PS->L2 COHERENCE BRIDGE (v14): the VEN core's memory path runs THROUGH the ao486 l2_cache
    // (shim: axi2avalon -> avm_* -> l2_cache -> DDRAM -> HP0). PS/daemon mmap writes never snoop it,
    // so PS-written guest RAM (e.g. injected BDA keys) stays STALE in the L2 forever — immune to the
    // ven_l1d flush (upstream) and the double-read (the L2 serves the repeat). On the SAME daemon
    // flush toggle (dbg_cmp[63] edge), fire a 32-pulse l2_fpu_inv train covering the BDA 0x400-0x4FF
    // (8B/beat), so one daemon knob invalidates the WHOLE path for injected-key visibility.
    reg fl_q0, fl_q1, fl_q2; reg [5:0] inv_cnt; reg inv_run;
    always @(posedge clk) begin
        if (rst) begin fl_q0<=1'b0; fl_q1<=1'b0; fl_q2<=1'b0; inv_cnt<=6'd0; inv_run<=1'b0; end
        else begin
            fl_q0 <= cpu_dbg_cmp[63]; fl_q1 <= fl_q0; fl_q2 <= fl_q1;
            if (fl_q1 ^ fl_q2) begin inv_run <= 1'b1; inv_cnt <= 6'd0; end
            else if (inv_run) begin
                if (inv_cnt == 6'd31) inv_run <= 1'b0;
                inv_cnt <= inv_cnt + 6'd1;
            end
        end
    end
    wire        l2inv_pulse = inv_run;
    wire [31:0] l2inv_addr  = 32'h400 + {23'd0, inv_cnt, 3'd0};

    ven_soc_dbg #(.DEPTH(128)) u_dbg (
        .clk(clk), .rst_n(resetn),
        .dbg_retire_valid(d_retire_valid), .dbg_eip(d_eip), .dbg_cs(d_cs), .dbg_esp(d_esp),
        .dbg_eflags(d_eflags), .dbg_state(d_state), .dbg_int_vec(d_int_vec), .dbg_fault_pc(d_fault_pc),
        .dbg_cr0(d_cr0), .io_pending(1'b0), .inta(d_inta),
        .ctrl_clear(dbg_clear), .freeze_thresh(dbg_freeze_thresh),
        .ext_freeze(dbg_ext_freeze | d_cmp_freeze | d_wr_freeze), .trace_rd_idx(dbg_trace_idx),  // d_wr_freeze: AW-to-0x80240 mid-copy
        .last_eip(dbg_last_eip), .last_cs(), .last_esp(), .last_eflags(),
        .frozen(dbg_frozen), .frozen_eip(dbg_frozen_eip),
        .frozen_ctx_eip(dbg_frozen_ctx_eip), .frozen_cs(dbg_frozen_cs),
        .frozen_esp(dbg_frozen_esp), .frozen_eflags(dbg_frozen_eflags),
        .frozen_fault_pc(dbg_frozen_fault_pc), .frozen_cr0(dbg_frozen_cr0),
        .frozen_state(dbg_frozen_state), .frozen_vec(dbg_frozen_vec),
        .trace_pc(dbg_trace_pc), .trace_aux(dbg_trace_aux), .trace_count(dbg_trace_count),
        .perf_cyc(dbg_perf_cyc), .perf_retired(dbg_perf_retired), .perf_stall(dbg_perf_stall), .perf_io(dbg_perf_io), .perf_irq(dbg_perf_irq),
        // 0x1A0/0x1B0 are assigned to the outer AXI profiler below.  The old
        // state-number bins were invalid once the feature defines moved them.
        .perf_st_pipe(), .perf_st_walk(),
        .perf_st_fetch(dbg_st_fetch), .perf_st_other(dbg_st_other),
        // VEN DIAG (build #9, CORE LOAD-SERVE forensics): the dbg_rd path now carries the L1D's core
        // read-serve (ventium_l1_axi retargeted dbg_rd -> c_addr/c_rdata). With the AW-to-0x80240 freeze
        // the ring holds the MOVSB SOURCE-LOAD serves for the copy region. If c_rdata for 0x910 is a
        // scancode TABLE (not the DDR code shown by the fill ring), the L1D SERVE is stale -> the confirmed
        // root cause; if 0x910 serves CODE, re-open the store/rename path (faithful-chain subtlety).
        // MINI-ILA: the l1_axi tap now pulses dbg_rd_valid EVERY cycle with the live handshake word in
        // d_rd_data and core_addr in d_rd_addr; enrich the 64-bit ring entry with the live core FSM state
        // + retire/inta so the frozen ring is a 128-cycle waveform into the wedge.
        .dbg_rd_valid(d_rd_valid), .dbg_rd_addr(d_rd_addr),
        .dbg_rd_data({24'd0, d_state, d_retire_valid, d_inta, d_rd_data}),
        .dbg_rd_ring_addr(dbg_rd_ring_addr), .dbg_rd_ring_data(dbg_rd_ring_data),
        .dbg_rd_ring_data_hi(dbg_rd_ring_data_hi), .dbg_rd_ring_count()
    );

    ven_mgmt_axil u_mgmt (
        .clk(clk), .rst_n(resetn),
        .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
        .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
        .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
        .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
        .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
        .mgmt_address(mgmt_address), .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata),
        .mgmt_write(mgmt_write), .mgmt_writedata(mgmt_writedata),
        .ide0_request(ide0_request), .ide1_request(ide1_request), .fdd_request(fdd_request),
        .cpu_hung(cpu_hung), .dbg_word(dbg_word), .dbg_word2(dbg_word2),
        .dbg_trace_idx(dbg_trace_idx), .dbg_clear(dbg_clear), .dbg_ext_freeze(dbg_ext_freeze),
        .dbg_freeze_thresh(dbg_freeze_thresh), .dbg_cmp_cfg(dbg_cmp_cfg), .dbg_cmp_range(dbg_cmp_range),
        .dbg_halt_req(dbg_halt_req), .dbg_step(dbg_step), .dbg_bp_en(dbg_bp_en),
        .dbg_bp_addr(dbg_bp_addr), .dbg_bp_clr(dbg_bp_clr), .dbg_arch_sel(dbg_arch_sel),
        .dbg_halted(d_halted), .dbg_arch_data(d_arch_data),
        .dbg_last_eip(dbg_last_eip), .dbg_frozen(dbg_frozen), .dbg_frozen_eip(dbg_frozen_eip),
        .dbg_frozen_ctx_eip(dbg_frozen_ctx_eip), .dbg_frozen_cs(dbg_frozen_cs),
        .dbg_frozen_esp(dbg_frozen_esp), .dbg_frozen_eflags(dbg_frozen_eflags),
        .dbg_frozen_fault_pc(dbg_frozen_fault_pc), .dbg_frozen_cr0(dbg_frozen_cr0),
        .dbg_frozen_state(dbg_frozen_state), .dbg_frozen_vec(dbg_frozen_vec),
        .dbg_trace_pc(dbg_trace_pc), .dbg_trace_aux(dbg_trace_aux), .dbg_trace_count(dbg_trace_count[5:0]),
        .dbg_rd_ring_addr(dbg_rd_ring_addr), .dbg_rd_ring_data(dbg_rd_ring_data),
        .dbg_rd_ring_data_hi(dbg_rd_ring_data_hi), .dbg_perf_stall(dbg_perf_stall),
        .dbg_perf_cyc(dbg_perf_cyc), .dbg_perf_retired(dbg_perf_retired),
        .dbg_perf_io(dbg_perf_io), .dbg_perf_irq(dbg_perf_irq), .dbg_cr0_live(d_cr0),
        .dbg_rd_beats(p_rd_beats), .dbg_ar_hs(p_ar_hs), .dbg_b_hs(p_b_hs),
        .dbg_st_pipe(p_rd_busy_cyc), .dbg_st_walk(p_rd_firstwait_cyc),
        .dbg_st_fetch(dbg_st_fetch), .dbg_st_other(dbg_st_other),
        .cap_arm(cap_arm), .cap_rd_addr(cap_rd_addr), .cap_rd_en(cap_rd_en), .cap_rd_data(cap_rd_data),
        .cap_frame_ready(cap_frame_ready), .cap_capture_active(cap_capture_active), .cap_frame_overrun(cap_frame_overrun),
        .cap_frame_sequence(cap_frame_sequence), .cap_frame_cycle(cap_frame_cycle),
        .cap_frame_width(cap_frame_width), .cap_frame_height(cap_frame_height), .cap_frame_pixels(cap_frame_pixels),
        .kbd_inject_data(kbd_inject_data), .kbd_inject_valid(kbd_inject_valid),
        .kbd_inject_ready(kbd_inject_ready), .kbd_inject_busy(kbd_inject_busy),
        .mouse_csr_write(mouse_csr_write), .mouse_csr_waddr(mouse_csr_waddr),
        .mouse_csr_wdata(mouse_csr_wdata), .mouse_csr_wstrb(mouse_csr_wstrb),
        .mouse_csr_raddr(mouse_csr_raddr), .mouse_csr_rdata(mouse_csr_rdata),
        .core_reset_n(core_reset_n), .irq_out(pl_ps_irq0)
    );

    ven_video_capture u_video_capture (
        .clk(clk), .rst_n(resetn),
        .arm(cap_arm), .rd_addr(cap_rd_addr), .rd_en(cap_rd_en), .rd_data(cap_rd_data),
        .video_ce(video_ce), .video_blank_n(video_blank_n),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .video_r(video_r), .video_g(video_g), .video_b(video_b),
        .frame_ready(cap_frame_ready), .capture_active(cap_capture_active), .frame_overrun(cap_frame_overrun),
        .frame_sequence(cap_frame_sequence), .frame_cycle(cap_frame_cycle),
        .frame_width(cap_frame_width), .frame_height(cap_frame_height), .frame_pixels(cap_frame_pixels)
    );

    // A normal PS/2 device endpoint for headless boards.  The AXI-Lite
    // register only queues device-originated scan-code bytes; the actual
    // 8042 receives them through its ordinary serial pins and raises IRQ1.
    ven_ps2_kbd_inject #(.CLK_HZ(CLK_HZ)) u_ps2_kbd_inject (
        .clk(clk), .rst_n(~soc_reset),
        .inject_valid(kbd_inject_valid), .inject_data(kbd_inject_data),
        .inject_ready(kbd_inject_ready), .inject_busy(kbd_inject_busy),
        .host_clk_release(ps2_kbclk_host), .host_dat_release(ps2_kbdat_host),
        .dev_clk_release(ps2_kbclk_dev), .dev_dat_release(ps2_kbdat_dev)
    );

    // Management ownership survives guest reset long enough to expose its
    // generation. The actual device uses the 8042's guest reset domain.
    ven_ps2_mailbox u_mouse_mailbox (
        .clk(clk), .rst_n(resetn), .guest_reset(soc_reset),
        .csr_write(mouse_csr_write), .csr_waddr(mouse_csr_waddr),
        .csr_wdata(mouse_csr_wdata), .csr_wstrb(mouse_csr_wstrb),
        .csr_raddr(mouse_csr_raddr), .csr_rdata(mouse_csr_rdata),
        .tx_valid(mouse_tx_valid), .tx_data(mouse_tx_data), .tx_ready(mouse_tx_ready),
        .tx_done(mouse_tx_done), .tx_aborted(mouse_tx_aborted),
        .rx_valid(mouse_rx_valid), .rx_data(mouse_rx_data), .rx_error(mouse_rx_error),
        .rx_ready(mouse_rx_ready), .rx_aborted(mouse_rx_aborted)
    );
    ven_ps2_device #(.CLK_HZ(CLK_HZ)) u_ps2_mouse_device (
        .clk(clk), .rst_n(~soc_reset),
        .tx_valid(mouse_tx_valid), .tx_data(mouse_tx_data), .tx_ready(mouse_tx_ready),
        .tx_done(mouse_tx_done), .tx_aborted(mouse_tx_aborted),
        .rx_valid(mouse_rx_valid), .rx_data(mouse_rx_data), .rx_error(mouse_rx_error),
        .rx_ready(mouse_rx_ready), .rx_aborted(mouse_rx_aborted),
        .host_clk_release(ps2_mouseclk_host), .host_dat_release(ps2_mousedat_host),
        .dev_clk_release(ps2_mouseclk_dev), .dev_dat_release(ps2_mousedat_dev)
    );

`ifdef VEN_DDR_POSTED
    ven_ddram_axi_posted #(.MEM_BASE(MEM_BASE), .WRITE_SLOTS(16)) u_ddr (
        .fault(ddr_posted_fault), .drained(ddr_posted_drained),
`else
    assign ddr_posted_fault = 1'b0;
    assign ddr_posted_drained = 1'b0;
    ven_ddram_axi #(.MEM_BASE(MEM_BASE)) u_ddr (
`endif
        .clk(clk), .rst_n(resetn),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .dbg_st(dbg_st)
    );

    // Physical timebases: all three clocks below run at the actual core/SoC
    // CLK_HZ.  Accelerated simulation rates must not be used on hardware:
    // PIT/RTC seconds and VGA pixel enables must track their real input clocks.
    system u_soc (
        .reset(soc_reset), .clk_sys(clk), .clock_rate(CLK_HZ[27:0]), .rtc_clock_rate(CLK_HZ[27:0]),
        // build #28: RE-ENABLE the ao486 L2 (revert Fix C). Build #27 proved the read corruption is a
        // downstream read-response mis-sync, and the non-standard L2-DISABLE-mode pipeline is a prime
        // suspect. The L2 ENABLED is the PROVEN ao486 path (boots Win95 on stock ao486). Barrier also off.
        .l1_disable(1'b0), .l2_disable(1'b0), .l2_fpu_inv_pulse(l2inv_pulse), .l2_fpu_inv_addr(l2inv_addr),
        .fdd_request(fdd_request), .ide0_request(ide0_request), .ide1_request(ide1_request), .floppy_wp(2'b00),
        .joystick_dis(2'b11), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
        .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
        .mgmt_address(mgmt_address), .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata),
        .mgmt_write(mgmt_write), .mgmt_writedata(mgmt_writedata),
        .ps2_kbclk_in(ps2_kbclk_in), .ps2_kbdat_in(ps2_kbdat_in),
        .ps2_kbclk_out(ps2_kbclk_host), .ps2_kbdat_out(ps2_kbdat_host),
        .ps2_mouseclk_in(ps2_mouseclk_host & ps2_mouseclk_dev),
        .ps2_mousedat_in(ps2_mousedat_host & ps2_mousedat_dev),
        .ps2_mouseclk_out(ps2_mouseclk_host), .ps2_mousedat_out(ps2_mousedat_host), .ps2_reset_n(),
        .bootcfg(6'd0), .uma_ram(1'b0), .syscfg(),
        .clk_uart1(clk), .uart1_rx(1'b1), .uart1_tx(), .uart1_cts_n(1'b1), .uart1_dcd_n(1'b1), .uart1_dsr_n(1'b1), .uart1_rts_n(), .uart1_dtr_n(),
        .clk_uart2(clk), .uart2_rx(1'b1), .uart2_tx(), .uart2_cts_n(1'b1), .uart2_dcd_n(1'b1), .uart2_dsr_n(1'b1), .uart2_rts_n(), .uart2_dtr_n(),
        .clk_mpu(clk), .mpu_rx(1'b1), .mpu_tx(),
        .clk_audio(clk), .sample_cms_l(), .sample_cms_r(), .sample_sb_l(), .sample_sb_r(), .sample_opl_l(), .sample_opl_r(),
        .sound_fm_mode(1'b0), .sound_cms_en(1'b0), .speaker_out(), .sbp(),
        .vol_master_l(), .vol_master_r(), .vol_voice_l(), .vol_voice_r(), .vol_midi_l(), .vol_midi_r(),
        .vol_cd_l(), .vol_cd_r(), .vol_line_l(), .vol_line_r(), .vol_spk(), .vol_en(),
        .clk_vga(clk), .clock_rate_vga(CLK_HZ[27:0]),
        .video_ce(video_ce), .video_blank_n(video_blank_n), .video_hsync(video_hsync), .video_vsync(video_vsync),
        .video_r(video_r), .video_g(video_g), .video_b(video_b), .video_f60(1'b0),
        .video_pal_a(), .video_pal_d(), .video_pal_we(),
        .video_start_addr(), .video_width(), .video_height(), .video_flags(), .video_stride(), .video_off(),
        .video_fb_en(1'b0), .video_lores(1'b1), .video_border(1'b0),
        .DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .cpu_dbg_bus(cpu_dbg_bus), .cpu_dbg_cmp(cpu_dbg_cmp)
    );

    // ---- status LEDs (also the structural anchor): heartbeat + core activity ----
    reg [24:0] hb; reg core_act;
    always @(posedge clk) begin
        if (rst) begin hb <= 25'd0; core_act <= 1'b0; end
        else begin hb <= hb + 1'b1; if (DDRAM_WE || DDRAM_RD) core_act <= ~core_act; end
    end
    assign led = { core_act, |ide0_request, core_reset_n, hb[24] };
endmodule
`default_nettype wire
