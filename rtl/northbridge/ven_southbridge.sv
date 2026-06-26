// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// northbridge/ven_southbridge.sv — the PIIX-style south-bridge wrapper (Phase D.2).
//
// The device side of the 430FX system: it presents the three interfaces the rest of the
// system needs and ties together the bridge-resident logic. The legacy ISA peripherals
// (PIC/PIT/RTC/i8042/i8272/IDE/UART) already exist in rtl/soc/*; THIS wrapper is the
// structural shell + the new bridge logic. Wiring the real legacy peripherals into the
// io-decode (and their IRQ lines) is done in the unified system top (Phase E) — kept out
// of this standalone module so it does not depend on those files mid-refactor.
//
//   northbridge.mmio_* ─►│ MMIO slave  ── VGA aperture framebuffer (0xA0000-0xBFFFF)
//   core.io_*          ─►│ port-I/O    ── 0xCF8/0xCFC PCI config → ven_hostbridge_cfg
//                        │                0x00C0-0x00CF DMA control → ven_i8237_dma
//   ven_i8237_dma ─────►│ DMA master  ── northbridge.dma_* (coherent bus mastering)
//   ven_hostbridge_cfg ►│ cfg_*       ── to northbridge.ven_cachemap
//
// PCI config (0xCF8 address / 0xCFC data) is decoded here and routed to the TSC host
// bridge config registers (bus0:dev0); the resulting cfg_* drive the northbridge cachemap.
// The DMA engine's device data port (dev_*) is exposed so a real disk/floppy (or, in the
// gate, a test device) supplies/consumes the transferred bytes.

`default_nettype none

module ven_southbridge (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // ---- MMIO slave (from northbridge.mmio_*) : memory-mapped device space ------
    input  wire logic        mmio_req,
    input  wire logic        mmio_we,
    input  wire logic [31:0] mmio_addr,
    input  wire logic [31:0] mmio_wdata,
    input  wire logic [3:0]  mmio_wstrb,
    output logic [31:0]      mmio_rdata,
    output logic             mmio_ack,

    // ---- port-I/O slave (from the core io_* bus) : PCI config + DMA control ------
    input  wire logic        io_req,
    input  wire logic        io_we,
    input  wire logic [15:0] io_addr,
    input  wire logic [31:0] io_wdata,
    output logic [31:0]      io_rdata,
    output logic             io_ack,

    // ---- DMA master (to northbridge.dma_*) : coherent bus mastering -------------
    output logic             dma_req,
    output logic             dma_we,
    output logic [31:0]      dma_addr,
    output logic [31:0]      dma_wdata,
    output logic [3:0]       dma_wstrb,
    input  wire logic [31:0] dma_rdata,
    input  wire logic        dma_ack,

    // ---- DMA device data (the I/O device: disk/floppy; the gate's test device) --
    output logic             dev_rd,
    input  wire logic [31:0] dev_rdata,
    output logic             dev_wr,
    output logic [31:0]      dev_wdata,
    output logic             dma_busy,
    output logic             dma_tc,

    // ---- TSC host-bridge cacheability registers → northbridge.cachemap ----------
    output logic [55:0]      cfg_pam,
    output logic [7:0]       cfg_dramc,
    output logic [7:0]       cfg_cc,
    output logic [7:0]       cfg_tom_mb4,
    output logic [7:0]       cfg_smram
);

  // ===========================================================================
  // PCI config mechanism (0xCF8 CONFIG_ADDRESS / 0xCFC CONFIG_DATA)
  // ===========================================================================
  logic [31:0] config_addr;                 // 0xCF8 latch
  wire  is_cf8 = (io_addr == 16'h0CF8);
  wire  is_cfc = (io_addr[15:2] == 14'h033F);   // 0xCFC..0xCFF
  // a config-data cycle targeting bus0:dev0:func0 (config_addr[23:8]==0, enable set).
  wire  cfg_hit = is_cfc && config_addr[31] && (config_addr[23:8]==16'h0000);
  logic [31:0] hostcfg_rdata;
  ven_hostbridge_cfg u_hcfg (
      .clk(clk), .rst_n(rst_n),
      .cfg_sel(io_req & cfg_hit), .cfg_we(io_we & cfg_hit),
      .cfg_off({config_addr[7:2], 2'b00}), .cfg_be(4'hF), .cfg_wdata(io_wdata),
      .cfg_rdata(hostcfg_rdata),
      .pam(cfg_pam), .dramc(cfg_dramc), .cc(cfg_cc), .tom_mb4(cfg_tom_mb4), .smram(cfg_smram));

  // ===========================================================================
  // 8237 DMA: the REAL register file (ven_i8237 at I/O 0x00-0x0F + page 0x80-0x8F)
  // drives the transfer engine (ven_i8237_dma). Channel 0 is wired to the engine;
  // the cascaded channels 1-3/secondary controller are a follow-up.
  // ===========================================================================
  logic [7:0]  i8237_rdata;
  logic [15:0] ch_addr [0:3], ch_count [0:3]; logic [7:0] ch_page [0:3], ch_mode [0:3];
  logic [3:0]  ch_mask, ch_xreq;
  wire is_dma8237 = (io_addr[15:4]==12'h000) || (io_addr[15:4]==12'h008);  // 0x00-0x0F, 0x80-0x8F
  ven_i8237 u_i8237 (
      .clk(clk), .rst(~rst_n), .cs(io_req & is_dma8237), .we(io_we),
      .addr(io_addr), .wdata(io_wdata[7:0]), .rdata(i8237_rdata),
      .ch_addr_o(ch_addr), .ch_count_o(ch_count), .ch_page_o(ch_page), .ch_mode_o(ch_mode),
      .ch_mask_o(ch_mask), .ch_xreq_o(ch_xreq));

  // channel 0 → the transfer engine. start = {page,addr} (8237 24-bit), count = N+1
  // (8257 stores N-1), dir from the mode transfer-type field (10=read mem→dev, 01=write).
  wire        ch0_go    = ch_xreq[0] & ~ch_mask[0];
  wire [31:0] ch0_start = {8'd0, ch_page[0], ch_addr[0]};
  wire [15:0] ch0_count = ch_count[0] + 16'd1;
  wire        ch0_dir   = (ch_mode[0][3:2]==2'b10);

  ven_i8237_dma u_dma (
      .clk(clk), .rst_n(rst_n),
      .go(ch0_go), .start_addr(ch0_start), .count(ch0_count), .dir(ch0_dir),
      .busy(dma_busy), .tc(dma_tc),
      .dev_rd(dev_rd), .dev_rdata(dev_rdata), .dev_wr(dev_wr), .dev_wdata(dev_wdata),
      .m_req(dma_req), .m_we(dma_we), .m_addr(dma_addr), .m_wdata(dma_wdata),
      .m_wstrb(dma_wstrb), .m_rdata(dma_rdata), .m_ack(dma_ack));

  // ---- port-I/O response: single-cycle ack; data from the selected block ------
  assign io_ack   = io_req;                  // all decoded ports ack in one cycle
  assign io_rdata = is_cf8      ? config_addr
                  : is_cfc      ? (cfg_hit ? hostcfg_rdata : 32'hFFFF_FFFF) // master-abort = all 1s
                  : is_dma8237  ? {24'd0, i8237_rdata}
                  : 32'd0;
  always_ff @(posedge clk) if (!rst_n) config_addr<=32'd0;
                            else if (io_req && io_we && is_cf8) config_addr<=io_wdata;

  // ===========================================================================
  // MMIO slave: the VGA aperture framebuffer (0xA0000-0xBFFFF), 128 KiB.
  // The northbridge streams a line read (WORDS words walking the address) and writes a
  // single word; we serve combinationally per the walking address (latency 1).
  // ===========================================================================
  (* ram_style = "block" *) logic [7:0] fb [0:(1<<17)-1];
  wire [16:0] fb_off = mmio_addr[16:0];
  always_comb begin
    mmio_ack = mmio_req;
    mmio_rdata = (mmio_req && !mmio_we) ? {fb[fb_off+3],fb[fb_off+2],fb[fb_off+1],fb[fb_off+0]} : 32'd0;
  end
  always_ff @(posedge clk) if (mmio_req && mmio_we)
    for (int b=0;b<4;b++) if (mmio_wstrb[b]) fb[fb_off+b] <= mmio_wdata[b*8 +: 8];

endmodule : ven_southbridge

`default_nettype wire
