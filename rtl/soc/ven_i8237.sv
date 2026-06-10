// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_i8237.sv — Ventium SoC PC peripheral: Intel 8237A DMA controller (M8.7).
//
// The PRIMARY (controller 0, 8-bit, channels 0-3) DMA controller at I/O 0x00-0x0F,
// plus the AT page registers it owns at 0x81/0x82/0x83/0x87. The cascaded secondary
// controller (0xC0-0xDF, 16-bit, channels 4-7) is a follow-up.
//
// GROUNDING (authoritative): QEMU 8.2.2 hw/dma/i8257.c (the 8237/8257 model),
// mirrored under ventium-refs/...../hw/dma/i8257.c. This module matches the
// CPU-OBSERVABLE register read/write behaviour (the M8.7 psoc8237 per-record
// differential checks it). dshift=0 (controller 0, byte addressing).
//
// Register map (iport = addr[3:0]):
//   0x00-0x07 channel addr/count : iport>>1 = channel, iport&1 = 0 addr / 1 count.
//             Both are 16-bit, accessed LSB-then-MSB through the shared FLIP-FLOP
//             (toggles on every channel read/write). A WRITE sets base[]; the MSB
//             write also runs init_chan (now[ADDR]=base[ADDR], now[COUNT]=0), so a
//             write-then-read ROUND-TRIPS: addr read = now[ADDR](=base[ADDR]),
//             count read = base[COUNT]-now[COUNT](=base[COUNT]).  (i8257 read/write_chan)
//   0x08 status(R, read-clears low nibble) / command(W)
//   0x09 mask(R) / request(W: DMA run — oracle boundary, never written here)
//   0x0A single-mask(W)   0x0B mode(W)   0x0C clear-flip-flop(W)
//   0x0D master-reset(W: ff=0,mask=~0,status=0,command=0) / temp(R=0)
//   0x0E clear-mask-all(W)   0x0F write-mask-all(W)
//   page 0x81->ch2, 0x82->ch3, 0x83->ch1, 0x87->ch0 (channels[]={-1,2,3,1,...,0}).
//
// ORACLE BOUNDARY (excluded, like the 8042 OBF / UART RX): the actual DMA memory
// transfer (i8257_dma_run / transfer_handler), DREQ/DACK, and TC generation — they
// need a device asserting DREQ + a host-clock loop the single-step golden cannot
// reproduce. The test never writes the request register (0x09) or unmasks a
// requesting channel, so `now[COUNT]` stays 0 and no transfer is ever attempted.

`default_nettype none

module ven_i8237 (
    input  wire logic        clk,
    input  wire logic        rst,        // synchronous, ACTIVE-HIGH (PC RESET)
    input  wire logic        cs,         // chip-select: a serviced DMA port hit
    input  wire logic        we,         // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  wire logic [15:0] addr,       // I/O port address
    input  wire logic [7:0]  wdata,
    output logic [7:0]       rdata        // COMBINATIONAL off the registers
);

  // ---- per-channel state (controller 0: 4 channels) ------------------------
  logic [15:0] base_addr  [0:3];
  logic [15:0] base_count [0:3];
  logic [15:0] now_addr   [0:3];   // set by init_chan on the MSB write (= base_addr)
  logic [7:0]  mode       [0:3];
  logic [7:0]  page       [0:3];
  // ---- controller state ----------------------------------------------------
  logic        flip_flop;          // LSB/MSB sequencer; toggles on channel rd/wr
  logic [7:0]  command;
  logic [7:0]  status;             // [7:4] DREQ pending, [3:0] TC reached
  logic [7:0]  mask;               // per-channel disable (1=masked)

  // ---- address decode ------------------------------------------------------
  wire        is_page = addr[7];                 // 0x80-0x8F range (cs gates exacts)
  wire        is_cont = !is_page && addr[3];      // 0x08-0x0F
  wire        is_chan = !is_page && !addr[3];     // 0x00-0x07
  wire [2:0]  ip      = addr[2:0];                // iport within the 8-port block
  wire [1:0]  ch      = addr[2:1];                // channel (chan block)
  wire        nreg    = addr[0];                  // 0=addr, 1=count

  // page port -> channel (channels[] = {-1,2,3,1,-1,-1,-1,0}); only 1/2/3/7 valid.
  function automatic logic [1:0] page_ch(input logic [2:0] idx);
    unique case (idx)
      3'd1: page_ch = 2'd2;   // 0x81 -> ch2
      3'd2: page_ch = 2'd3;   // 0x82 -> ch3
      3'd3: page_ch = 2'd1;   // 0x83 -> ch1
      3'd7: page_ch = 2'd0;   // 0x87 -> ch0
      default: page_ch = 2'd0;
    endcase
  endfunction

  // ---- combinational read (uses the CURRENT flip_flop for the byte select) --
  logic [15:0] rd_chan_val;
  always_comb begin
    // addr read = now[ADDR] + now[COUNT]*dir ; count read = base[COUNT]-now[COUNT].
    // now[COUNT] is always 0 here (no DMA), so: addr=now_addr, count=base_count.
    rd_chan_val = nreg ? base_count[ch] : now_addr[ch];
    rdata = 8'h00;
    if (is_page) begin
      rdata = page[page_ch(ip)];
    end else if (is_chan) begin
      rdata = flip_flop ? rd_chan_val[15:8] : rd_chan_val[7:0];
    end else begin // cont
      unique case (ip)
        3'd0:    rdata = status;   // 0x08 status
        3'd1:    rdata = mask;     // 0x09 mask
        default: rdata = 8'h00;    // 0x0D temp etc. = 0
      endcase
    end
  end

  // ---- clocked writes + read side-effects ----------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      // i8257_reset == write_cont(RESET): ff=0, mask=~0, status=0, command=0.
      flip_flop <= 1'b0;
      mask      <= 8'hFF;
      status    <= 8'h00;
      command   <= 8'h00;
      for (int i = 0; i < 4; i++) begin
        base_addr[i]  <= 16'd0; base_count[i] <= 16'd0;
        now_addr[i]   <= 16'd0; mode[i] <= 8'd0; page[i] <= 8'd0;
      end
    end else if (cs && we) begin
      // -------- CPU OUT --------
      if (is_page) begin
        page[page_ch(ip)] <= wdata;
      end else if (is_chan) begin
        if (!flip_flop) begin
          if (nreg) base_count[ch][7:0] <= wdata;
          else      base_addr [ch][7:0] <= wdata;
          flip_flop <= 1'b1;
        end else begin
          // MSB write + init_chan: now_addr = base_addr (with this new high byte if
          // this was the addr write), now_count = 0. base_addr's high byte updates
          // here, and now_addr takes the post-write base_addr.
          logic [15:0] new_addr;
          new_addr = nreg ? base_addr[ch] : {wdata, base_addr[ch][7:0]};
          if (nreg) base_count[ch][15:8] <= wdata;
          else      base_addr [ch][15:8] <= wdata;
          now_addr[ch] <= new_addr;             // init_chan (dshift=0); now_count=0
          flip_flop    <= 1'b0;
        end
      end else begin // cont 0x08-0x0F
        unique case (ip)
          3'd0: command <= wdata;                       // command
          3'd1: ;                                       // request (DMA run) — boundary
          3'd2: if (wdata[2]) mask <= mask |  (8'h1 << wdata[1:0]); // single mask set
                else          mask <= mask & ~(8'h1 << wdata[1:0]); // single mask clr
          3'd3: mode[wdata[1:0]] <= wdata;              // mode
          3'd4: flip_flop <= 1'b0;                      // clear flip-flop
          3'd5: begin flip_flop<=1'b0; mask<=8'hFF; status<=8'h00; command<=8'h00; end // reset
          3'd6: mask <= 8'h00;                          // clear mask (all)
          3'd7: mask <= wdata;                          // write mask (all)
          default: ;
        endcase
      end
    end else if (cs && !we) begin
      // -------- CPU IN (side effects) --------
      // channel read toggles the flip-flop (getff); status read clears low nibble.
      if (is_chan)                     flip_flop <= ~flip_flop;
      else if (is_cont && ip == 3'd0)  status    <= status & 8'hF0;
    end
  end

endmodule : ven_i8237

`default_nettype wire
