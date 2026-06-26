// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_i8237_dma.sv — the 8237 DMA TRANSFER ENGINE (Phase D.3).
//
// ven_i8237.sv models the CPU-observable 8237 REGISTER file (the differential-tested
// surface) but the actual memory transfer is its documented "oracle boundary". This
// module is that transfer engine: given a programmed channel (24/32-bit start address,
// word count, direction), it moves the block between a DEVICE data port and system
// MEMORY, presenting a word-granular backing MASTER (m_*) that the northbridge arbitrates
// into the L2 — so a DMA write is coherent (the NB snoops the CPU L1) and a DMA read sees
// dirty L2 data. The southbridge pairs this with ven_i8237's registers (the register file
// drives `go`/`start_addr`/`count`/`dir`; this engine drives the bus + DACK/TC).
//
//   ven_i8237 (regs) ──(go,addr,count,dir)──► ven_i8237_dma ──(m_*)──► northbridge.dma_*
//                                                  ▲ dev_* │
//                                            I/O device (disk/floppy)
//
// DIRECTION (8257 semantics):
//   dir=0  WRITE transfer — device → memory (e.g. a disk READ filling a buffer): the
//          engine pulls a word from the device (dev_rd/dev_rdata) and WRITES it to memory.
//   dir=1  READ  transfer — memory → device (e.g. a disk WRITE draining a buffer): the
//          engine READS a word from memory and pushes it to the device (dev_wr/dev_wdata).
//
// GRANULARITY: word (32-bit) transfers — the natural backing unit. Memory writes are a
// single backing transaction; memory reads follow the line protocol (the L2/NB stream
// WORDS words per read), so the engine reads the line containing the address and takes
// the addressed word. Byte (8-bit ISA channel) granularity is a later refinement.

`default_nettype none

module ven_i8237_dma #(
    parameter int LINE = 32                 // backing line bytes (== L2 line); WORDS=8
) (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // ---- programming (from the ven_i8237 register file / southbridge) ----------
    input  wire logic        go,            // 1-clock start pulse (channel unmasked + DREQ)
    input  wire logic [31:0] start_addr,    // memory start address (page<<16 | offset)
    input  wire logic [15:0] count,         // number of WORDS to transfer (>=1)
    input  wire logic        dir,           // 0 = device→mem (write), 1 = mem→device (read)
    output logic             busy,          // 1 while a transfer is in flight
    output logic             tc,            // 1-clock terminal-count pulse at completion

    // ---- device data interface (the I/O device side) --------------------------
    output logic             dev_rd,        // 1-clock: take dev_rdata (dir=0)
    input  wire logic [31:0] dev_rdata,
    output logic             dev_wr,        // 1-clock: dev_wdata is valid (dir=1)
    output logic [31:0]      dev_wdata,

    // ---- memory backing MASTER (→ northbridge dma_*) --------------------------
    output logic             m_req,
    output logic             m_we,
    output logic [31:0]      m_addr,
    output logic [31:0]      m_wdata,
    output logic [3:0]       m_wstrb,
    input  wire logic [31:0] m_rdata,
    input  wire logic        m_ack
);
  localparam int WORDS = LINE/4;

  typedef enum logic [2:0] { S_IDLE, S_WGET, S_WR, S_RD, S_RDEV, S_DONE } state_e;
  state_e        st;
  logic [31:0]   addr;
  logic [15:0]   cnt;
  logic          dir_q;
  logic [31:0]   wbuf;                       // word to write (dir=0)
  logic [31:0]   rbuf [WORDS];               // captured read line (dir=1)
  logic [$clog2(WORDS):0] rcnt;              // read-beat counter

  // ---- backing master drive (combinational) ---------------------------------
  always_comb begin
    m_req=1'b0; m_we=1'b0; m_addr=32'd0; m_wdata=32'd0; m_wstrb=4'd0;
    if (st==S_WR) begin
      m_req=1'b1; m_we=1'b1; m_addr=addr; m_wdata=wbuf; m_wstrb=4'hF;
    end else if (st==S_RD) begin
      m_req=1'b1; m_we=1'b0; m_addr={addr[31:5],5'd0}; // line base; L2 streams WORDS words
    end
  end

  // ---- device strobes (combinational, 1-clock in their state) ----------------
  assign dev_rd    = (st==S_WGET);
  assign dev_wr    = (st==S_RDEV);
  assign dev_wdata = rbuf[addr[4:2]];
  assign busy      = (st!=S_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=S_IDLE; addr<=32'd0; cnt<=16'd0; dir_q<=1'b0; wbuf<=32'd0; rcnt<='0; tc<=1'b0;
    end else begin
      tc <= 1'b0;
      unique case (st)
        S_IDLE: if (go) begin
          addr<=start_addr; cnt<=count; dir_q<=dir; rcnt<='0;
          st <= dir ? S_RD : S_WGET;
        end
        // ---- device→mem (WRITE) ----
        S_WGET: begin wbuf <= dev_rdata; st <= S_WR; end   // latch the device word
        S_WR:   if (m_ack) begin
          addr <= addr + 32'd4;
          if (cnt==16'd1) st <= S_DONE;
          else begin cnt <= cnt - 16'd1; st <= S_WGET; end
        end
        // ---- mem→device (READ) ----
        S_RD: if (m_ack) begin
          rbuf[rcnt] <= m_rdata;
          if (rcnt==WORDS-1) begin rcnt<='0; st<=S_RDEV; end
          else rcnt <= rcnt + 1'b1;
        end
        S_RDEV: begin                                       // dev_wr pulses this clock
          addr <= addr + 32'd4;
          if (cnt==16'd1) st <= S_DONE;
          else begin cnt <= cnt - 16'd1; st <= S_RD; end
        end
        S_DONE: begin tc <= 1'b1; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // never assert both directions; never drive the bus outside its states.
  assert_dir: assert property (@(posedge clk) disable iff(!rst_n) !(dev_rd && dev_wr));
`endif

endmodule : ven_i8237_dma

`default_nettype wire
