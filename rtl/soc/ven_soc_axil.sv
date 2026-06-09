// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_soc_axil.sv — PS<->PL control + port-I/O bridge AXI4-Lite slave (KV260, F2).
//
// The KV260 SoC is PS-ASSISTED: the PL holds only the core + L1 + the AXI4 master to
// PS-DDR; the PS A53 emulates ALL slow peripherals in software (the cosim's C++ device
// models, moved onto the A53). This slave is the control + I/O seam between them, on
// PS M_AXI_HPM0_FPD. It does THREE jobs:
//   1. CONTROL: the PS holds the core in reset (CORE_RUN=0 at reset), writes the boot
//      config (init_eip/init_esp/boot_mode + mode bits), then releases CORE_RUN to run.
//   2. STATUS:  the PS reads cpu_hung / bus_err and the retire counter.
//   3. PORT-I/O BRIDGE: the core's IN/OUT (io_* bus) is captured here; the core STALLS
//      cleanly in S_IO (`if (io_ack) ...` with no else — core_io.svh:22-41) so the
//      bridge simply HOLDS io_ack=0, raises an interrupt to the PS, and on the PS's ACK
//      pulses io_ack=1 for ONE cycle with the IN data. No core RTL change needed.
//
// Single pl_clk0 domain (== the core/L1/HPC0 clock), so the io_* seam has NO CDC — only
// the level-high irq_out crosses to the GIC. All gated into the KV260 build; the default
// cosim build never instantiates this, so M0-M14 stay byte-identical.
//
// The int-0x80 syscall window (offsets 0x40-0x6C) + its ports are RESERVED here for the
// Quake user-mode path (F4, +VEN_PS_PROXY, the gated S_SYSCALL_WAIT core change); this
// A1 deliverable implements the control + status + retire + IO seam that F2/F3 need.

module ven_soc_axil #(
    parameter int AXIL_AW = 16,                 // 64 KiB aperture
    parameter logic [31:0] IDENT = 32'h5654_4D43 // "VTMC"
) (
    input  logic        clk,                    // pl_clk0
    input  logic        aresetn,                // peripheral_aresetn (active-low)

    // ---- AXI4-Lite slave (PS M_AXI_HPM0_FPD) ----------------------------------
    input  logic [AXIL_AW-1:0] s_axil_awaddr,
    input  logic [2:0]         s_axil_awprot,
    input  logic               s_axil_awvalid,
    output logic               s_axil_awready,
    input  logic [31:0]        s_axil_wdata,
    input  logic [3:0]         s_axil_wstrb,
    input  logic               s_axil_wvalid,
    output logic               s_axil_wready,
    output logic [1:0]         s_axil_bresp,
    output logic               s_axil_bvalid,
    input  logic               s_axil_bready,
    input  logic [AXIL_AW-1:0] s_axil_araddr,
    input  logic [2:0]         s_axil_arprot,
    input  logic               s_axil_arvalid,
    output logic               s_axil_arready,
    output logic [31:0]        s_axil_rdata,
    output logic [1:0]         s_axil_rresp,
    output logic               s_axil_rvalid,
    input  logic               s_axil_rready,

    // ---- control out -> core boot/config (latched by the core at its reset edge) --
    output logic        core_rst_n,             // = aresetn & CORE_RUN (core's reset)
    output logic [31:0] init_eip,
    output logic [31:0] init_esp,
    output logic        boot_mode,
    output logic        cycle_mode,
    output logic        bus_mode,
    output logic        l1axi_en,
    output logic        proxy_en,
    output logic        cosim_en,
    output logic [4:0]  errata_en,
    output logic        flush_all,              // W1P pulse from CTRL.FLUSH_ALL_REQ

    // ---- status in <- core --------------------------------------------------------
    input  logic        cpu_hung,
    input  logic        bus_err,
    input  logic [63:0] retire_n,

    // ---- port-I/O bridge <-> core io_* bus ----------------------------------------
    input  logic        io_req,
    input  logic        io_we,
    input  logic [15:0] io_addr,
    input  logic [2:0]  io_size,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        io_ack,

    // ---- interrupt to PS (GIC pl_ps_irq0) -----------------------------------------
    output logic        irq_out
);

  // ---- register offsets (word addresses; low bits of awaddr/araddr) -------------
  localparam logic [7:0] R_CTRL      = 8'h00;
  localparam logic [7:0] R_STATUS    = 8'h04;
  localparam logic [7:0] R_INIT_EIP  = 8'h08;
  localparam logic [7:0] R_INIT_ESP  = 8'h0C;
  localparam logic [7:0] R_MODE      = 8'h10;
  localparam logic [7:0] R_RETIRE_LO = 8'h14;
  localparam logic [7:0] R_RETIRE_HI = 8'h18;
  localparam logic [7:0] R_IO_STATUS = 8'h20;
  localparam logic [7:0] R_IO_ADDR   = 8'h24;
  localparam logic [7:0] R_IO_SIZE   = 8'h28;
  localparam logic [7:0] R_IO_WDATA  = 8'h2C;
  localparam logic [7:0] R_IO_RDATA  = 8'h30;
  localparam logic [7:0] R_IO_CTRL   = 8'h34;  // W1P: [0]ACK [1]IRQ_CLR
  localparam logic [7:0] R_IRQ_STAT  = 8'h70;  // R/W1C
  localparam logic [7:0] R_IDENT     = 8'h7C;

  // ---- control / config registers ----------------------------------------------
  logic        core_run;
  logic        irq_en;
  logic [31:0] init_eip_r, init_esp_r;
  logic        boot_mode_r, cycle_mode_r, bus_mode_r, l1axi_en_r, proxy_en_r, cosim_en_r;
  logic [4:0]  errata_en_r;
  logic [31:0] io_rdata_r;       // PS-written IN return value (staged for the ack)
  logic [31:0] hi_snap;          // retire_n[63:32] snapshot, latched on RETIRE_LO read

  assign core_rst_n = aresetn & core_run;
  assign init_eip   = init_eip_r;
  assign init_esp   = init_esp_r;
  assign boot_mode  = boot_mode_r;
  assign cycle_mode = cycle_mode_r;
  assign bus_mode   = bus_mode_r;
  assign l1axi_en   = l1axi_en_r;
  assign proxy_en   = proxy_en_r;
  assign cosim_en   = cosim_en_r;
  assign errata_en  = errata_en_r;

  // ---- port-I/O capture/release FSM ---------------------------------------------
  // IDLE -> (io_req) capture + raise irq, WAIT_PS (io_ack held 0) -> (PS ACK) RELEASE
  // (io_ack=1 one cycle, io_rdata valid) -> DONE (clear pending) -> IDLE.
  typedef enum logic [1:0] { IO_IDLE, IO_WAIT, IO_RELEASE, IO_DONE } iostate_e;
  iostate_e    iost;
  logic        io_pending;       // sticky: a request is captured + awaiting PS service
  logic        io_we_q;
  logic [15:0] io_addr_q;
  logic [2:0]  io_size_q;
  logic [31:0] io_wdata_q;
  logic        io_ack_r;
  logic        ps_ack_pulse;     // 1-cycle, set when the PS writes IO_CTRL.ACK
  logic        irq_clr_pulse;    // 1-cycle, set when the PS writes IO_CTRL.IRQ_CLR or W1C IRQ_STAT
  logic        irq_pending;      // sticky IRQ latch (set on capture, cleared by the PS)

  assign io_ack   = io_ack_r;
  assign io_rdata = io_rdata_r;
  assign irq_out  = irq_en & irq_pending;

  // ================= AXI4-Lite write channel =================
  logic [7:0] waddr;             // low byte of awaddr (word-decoded)
  logic       wr_fire;           // a register write commits this cycle
  assign wr_fire = s_axil_awvalid && s_axil_wvalid && s_axil_awready && s_axil_wready;
  assign waddr   = s_axil_awaddr[7:0];

  // accept AW+W together when not holding a B response (single-beat).
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      s_axil_awready <= 1'b0; s_axil_wready <= 1'b0;
      s_axil_bvalid  <= 1'b0; s_axil_bresp  <= 2'b00;
    end else begin
      // one-cycle ready pulse when both valids present and no B outstanding.
      if (s_axil_awvalid && s_axil_wvalid && !s_axil_awready && !(s_axil_bvalid && !s_axil_bready)) begin
        s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
      end else begin
        s_axil_awready <= 1'b0; s_axil_wready <= 1'b0;
      end
      // raise B on the accepted write; clear when accepted.
      if (wr_fire)                        s_axil_bvalid <= 1'b1;
      else if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    end
  end

  // ================= AXI4-Lite read channel =================
  logic [7:0] raddr;
  logic       rd_fire;           // a read accepted (araddr captured) this cycle
  assign raddr   = s_axil_araddr[7:0];
  assign rd_fire = s_axil_arvalid && s_axil_arready;
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      s_axil_arready <= 1'b0; s_axil_rvalid <= 1'b0;
      s_axil_rresp   <= 2'b00; s_axil_rdata <= 32'd0;
    end else begin
      // accept a read when AR present and no R outstanding.
      if (s_axil_arvalid && !s_axil_arready && !(s_axil_rvalid && !s_axil_rready))
        s_axil_arready <= 1'b1;
      else
        s_axil_arready <= 1'b0;
      if (rd_fire) begin
        s_axil_rvalid <= 1'b1;
        unique case (raddr)
          R_CTRL:      s_axil_rdata <= {23'd0, irq_en, 5'd0, 1'b0 /*rst_req W1P*/, 1'b0 /*flush W1P*/, core_run};
          R_STATUS:    s_axil_rdata <= {22'd0, 1'b0 /*sys_pend*/, io_pending, 5'd0, ~aresetn, bus_err, cpu_hung};
          R_INIT_EIP:  s_axil_rdata <= init_eip_r;
          R_INIT_ESP:  s_axil_rdata <= init_esp_r;
          R_MODE:      s_axil_rdata <= {19'd0, errata_en_r, 2'd0, cosim_en_r, proxy_en_r, l1axi_en_r, bus_mode_r, cycle_mode_r, boot_mode_r};
          R_RETIRE_LO: s_axil_rdata <= retire_n[31:0];   // (HI snapshot handled below)
          R_RETIRE_HI: s_axil_rdata <= hi_snap;
          R_IO_STATUS: s_axil_rdata <= {28'd0, 1'b0 /*is_ins*/, io_pending /*busy*/, io_we_q, io_pending};
          R_IO_ADDR:   s_axil_rdata <= {16'd0, io_addr_q};
          R_IO_SIZE:   s_axil_rdata <= {29'd0, io_size_q};
          R_IO_WDATA:  s_axil_rdata <= io_wdata_q;
          R_IO_RDATA:  s_axil_rdata <= io_rdata_r;
          R_IRQ_STAT:  s_axil_rdata <= {31'd0, irq_pending};
          R_IDENT:     s_axil_rdata <= IDENT;
          default:     s_axil_rdata <= 32'h0;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end
  // snapshot retire_n[63:32] when RETIRE_LO is read (torn-read-free 64-bit reads).
  always_ff @(posedge clk)
    if (!aresetn) hi_snap <= 32'd0;
    else if (rd_fire && raddr == R_RETIRE_LO) hi_snap <= retire_n[63:32];

  // ================= register write decode =================
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      core_run <= 1'b0;          // PS holds the core in reset until it releases CORE_RUN
      irq_en <= 1'b0;
      init_eip_r <= 32'd0; init_esp_r <= 32'd0;
      boot_mode_r <= 1'b0; cycle_mode_r <= 1'b0; bus_mode_r <= 1'b0;
      l1axi_en_r <= 1'b0; proxy_en_r <= 1'b0; cosim_en_r <= 1'b0; errata_en_r <= 5'd0;
      io_rdata_r <= 32'd0;
      flush_all <= 1'b0; ps_ack_pulse <= 1'b0; irq_clr_pulse <= 1'b0;
    end else begin
      flush_all     <= 1'b0;     // W1P: default low, pulse one cycle on the write
      ps_ack_pulse  <= 1'b0;
      irq_clr_pulse <= 1'b0;
      if (wr_fire) begin
        unique case (waddr)
          R_CTRL: begin
            if (s_axil_wstrb[0]) begin
              core_run <= s_axil_wdata[0];
              if (s_axil_wdata[1]) flush_all <= 1'b1;          // W1P FLUSH_ALL_REQ
              if (s_axil_wdata[2]) core_run  <= 1'b0;          // W1P CORE_RST_REQ -> drop run
            end
            if (s_axil_wstrb[1]) irq_en <= s_axil_wdata[8];
          end
          R_INIT_EIP: begin
            if (s_axil_wstrb[0]) init_eip_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) init_eip_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) init_eip_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) init_eip_r[31:24] <= s_axil_wdata[31:24];
          end
          R_INIT_ESP: begin
            if (s_axil_wstrb[0]) init_esp_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) init_esp_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) init_esp_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) init_esp_r[31:24] <= s_axil_wdata[31:24];
          end
          R_MODE: if (s_axil_wstrb[0]) begin
            boot_mode_r <= s_axil_wdata[0]; cycle_mode_r <= s_axil_wdata[1];
            bus_mode_r  <= s_axil_wdata[2]; l1axi_en_r   <= s_axil_wdata[3];
            proxy_en_r  <= s_axil_wdata[4]; cosim_en_r   <= s_axil_wdata[5];
            if (s_axil_wstrb[1]) errata_en_r <= s_axil_wdata[12:8];
          end
          R_IO_RDATA: begin
            if (s_axil_wstrb[0]) io_rdata_r[7:0]   <= s_axil_wdata[7:0];
            if (s_axil_wstrb[1]) io_rdata_r[15:8]  <= s_axil_wdata[15:8];
            if (s_axil_wstrb[2]) io_rdata_r[23:16] <= s_axil_wdata[23:16];
            if (s_axil_wstrb[3]) io_rdata_r[31:24] <= s_axil_wdata[31:24];
          end
          R_IO_CTRL: if (s_axil_wstrb[0]) begin
            if (s_axil_wdata[0]) ps_ack_pulse  <= 1'b1;        // commit RDATA + ack the core
            if (s_axil_wdata[1]) irq_clr_pulse <= 1'b1;        // clear the IRQ latch
          end
          R_IRQ_STAT: if (s_axil_wstrb[0] && s_axil_wdata[0]) irq_clr_pulse <= 1'b1; // W1C
          default: ;
        endcase
      end
    end
  end

  // ================= port-I/O capture/release FSM =================
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      iost <= IO_IDLE; io_pending <= 1'b0; io_ack_r <= 1'b0; irq_pending <= 1'b0;
      io_we_q <= 1'b0; io_addr_q <= 16'd0; io_size_q <= 3'd0; io_wdata_q <= 32'd0;
    end else begin
      io_ack_r <= 1'b0;                       // default: ack low (one-cycle pulse in RELEASE)
      if (irq_clr_pulse) irq_pending <= 1'b0; // PS cleared the interrupt
      unique case (iost)
        IO_IDLE: if (io_req) begin
          // capture the request (stable for the whole S_IO stall) + flag the PS.
          io_we_q    <= io_we;    io_addr_q <= io_addr;
          io_size_q  <= io_size;  io_wdata_q <= io_wdata;
          io_pending <= 1'b1;     irq_pending <= 1'b1;
          iost <= IO_WAIT;
        end
        IO_WAIT: if (ps_ack_pulse) begin
          // PS has written IO_RDATA (already in io_rdata_r) -> release the core.
          iost <= IO_RELEASE;
        end
        IO_RELEASE: begin
          io_ack_r <= 1'b1;       // single-cycle ack; the core latches io_rdata + advances
          iost <= IO_DONE;
        end
        IO_DONE: begin
          io_pending <= 1'b0;     // the core has left S_IO (io_req dropped); re-arm
          iost <= IO_IDLE;
        end
        default: iost <= IO_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // io_ack is exactly one cycle per release (the core needs precisely one ack edge).
  ioack_pulse: assert property (@(posedge clk) disable iff (!aresetn)
      io_ack_r |=> !io_ack_r);
  // never ack without a captured pending request.
  ioack_pending: assert property (@(posedge clk) disable iff (!aresetn)
      io_ack_r |-> io_pending);
  // AXI-Lite: BVALID/RVALID hold until accepted.
  b_hold: assert property (@(posedge clk) disable iff (!aresetn)
      (s_axil_bvalid && !s_axil_bready) |=> s_axil_bvalid);
  r_hold: assert property (@(posedge clk) disable iff (!aresetn)
      (s_axil_rvalid && !s_axil_rready) |=> s_axil_rvalid && $stable(s_axil_rdata));
`endif

endmodule : ven_soc_axil
