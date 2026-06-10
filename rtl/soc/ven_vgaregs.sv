// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// ven_vgaregs.sv -- Ventium SoC (M8) VGA register file device
//
// SCOPE: the CPU-observable VGA *register set* + its side effects ONLY. This is
// NOT the framebuffer / scan-out / display path (that is a later stage). It
// models exactly the I/O-port read/write behavior a guest CPU can observe.
//
// PORTS: 0x3b0..0x3df (the standard VGA register window). Color/mono aliasing is
// selected by MISC bit0 (VGA_MIS_COLOR): when set, 0x3b0..0x3bf are invalid
// (reads -> 0xff, writes ignored); when clear, 0x3d0..0x3df are invalid.
//
// GROUNDING: behavior matched to QEMU 8.2.2 hw/display/vga.c
//   vga_ioport_read()  (line 349) / vga_ioport_write() (line 439)
//   vga_ioport_invalid() (line 338), sr_mask[] (line 63), gr_mask[] (line 74),
//   vga_dumb_retrace() (line 333), vga_common_reset() (line 1810).
// Register macros from hw/display/vga_regs.h.
//
// Modeled register pairs / side effects:
//   - ATTR    0x3c0 W (ar_flip_flop toggles index/data each write) / 0x3c1 R
//   - MISC    0x3c2 W / 0x3cc R (msr), 0x3c2 R (st00), 0x3ca R (fcr)
//   - SEQ     0x3c4 index / 0x3c5 data (sr[], per-index sr_mask write masks)
//   - DAC     0x3c8 write-index / 0x3c7 read-index / 0x3c9 data
//             (768-byte palette, dac_sub_index 0/1/2 auto-increments the
//              index after 3 accesses; write goes through a 3-byte cache)
//   - GFX     0x3ce index / 0x3cf data (gr[], per-index gr_mask write masks)
//   - CRTC    0x3d4/0x3b4 index / 0x3d5/0x3b5 data (cr[]; CR0-7 write-locked
//             when CR11 bit7 set, except CR7 bit4 which is always writable)
//   - IS1     0x3da/0x3ba R : returns toggling retrace bits (dumb retrace =
//             st01 ^ 0x09) AND resets the attr flip-flop
//
// INTERFACE CONTRACT (shared by all ven_* devices for the SoC PMIO decoder):
//   WRITES commit on the clocked edge when (cs & we).
//   READS are combinational (rdata = addressed register, with read side-effects
//   -- DAC auto-increment, IS1 retrace toggle + ff reset -- applied on the
//   clocked edge when cs & ~we).
//   rst is SYNCHRONOUS, ACTIVE-HIGH (PC RESET).
// ============================================================================

module ven_vgaregs (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high (PC RESET)
    input  logic        cs,         // chip-select (SoC decoder asserts on hit)
    input  logic        we,         // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  logic [15:0] addr,       // I/O port address
    input  logic [7:0]  wdata,      // write data (byte device)
    output logic [7:0]  rdata,      // read data -- COMBINATIONAL off the regs

    // ---- M8.6: live mode bits exposed for the chain-4 framebuffer (ven_vga_fb).
    // Additive, outputs only -- the rdata-graded register differential (pvga) is
    // unaffected. SEQ[2]=plane-write mask, SEQ[4]=memory mode (bit3 CHN_4M),
    // GFX[5]=mode, GFX[6]=misc (bits3:2 memory-map mode).
    output logic [7:0]  o_seq_plane_mask, // SEQ idx 2
    output logic [7:0]  o_seq_mem_mode,   // SEQ idx 4
    output logic [7:0]  o_gfx_mode,       // GFX idx 5
    output logic [7:0]  o_gfx_misc        // GFX idx 6
);

    // ---- QEMU register port addresses (vga_regs.h) ------------------------
    localparam logic [15:0] VGA_ATT_W  = 16'h3C0; // attr index/data write
    localparam logic [15:0] VGA_ATT_R  = 16'h3C1; // attr data read
    localparam logic [15:0] VGA_MIS_W  = 16'h3C2; // misc output write / st00 read
    localparam logic [15:0] VGA_SEQ_I  = 16'h3C4; // sequencer index
    localparam logic [15:0] VGA_SEQ_D  = 16'h3C5; // sequencer data
    localparam logic [15:0] VGA_PEL_IR = 16'h3C7; // DAC read index (W) / dac_state (R)
    localparam logic [15:0] VGA_PEL_IW = 16'h3C8; // DAC write index
    localparam logic [15:0] VGA_PEL_D  = 16'h3C9; // DAC palette data
    localparam logic [15:0] VGA_FTC_R  = 16'h3CA; // feature control read (fcr)
    localparam logic [15:0] VGA_MIS_R  = 16'h3CC; // misc output read (msr)
    localparam logic [15:0] VGA_GFX_I  = 16'h3CE; // graphics index
    localparam logic [15:0] VGA_GFX_D  = 16'h3CF; // graphics data
    localparam logic [15:0] VGA_CRT_IC = 16'h3D4; // CRTC index (color)
    localparam logic [15:0] VGA_CRT_IM = 16'h3B4; // CRTC index (mono)
    localparam logic [15:0] VGA_CRT_DC = 16'h3D5; // CRTC data (color)
    localparam logic [15:0] VGA_CRT_DM = 16'h3B5; // CRTC data (mono)
    localparam logic [15:0] VGA_IS1_RC = 16'h3DA; // input status 1 (color)
    localparam logic [15:0] VGA_IS1_RM = 16'h3BA; // input status 1 (mono)

    // ---- QEMU constants ---------------------------------------------------
    // VGA_MIS_COLOR (vga_regs.h) == msr bit0; used directly as msr[0] below.
    localparam logic [4:0]  VGA_ATT_C           = 5'h15; // #attr regs (0x15)
    localparam logic [7:0]  VGA_CR11_LOCK       = 8'h80; // CR11 bit7 lock CR0-7
    localparam logic [7:0]  VGA_CRTC_OVERFLOW   = 8'h07; // CR7  (cr[] index)
    localparam logic [7:0]  VGA_CRTC_V_SYNC_END = 8'h11; // CR11 (cr[] index)
    localparam logic [7:0]  ST01_TOGGLE         = 8'h09; // V_RETRACE|DISP_ENABLE

    // ---- Architectural state (matches VGACommonState fields) --------------
    logic [5:0]  ar_index;       // attribute index (6 bits; QEMU masks val&0x3f)
    logic        ar_flip_flop;   // 0 = index phase, 1 = data phase
    logic [7:0]  ar  [0:20];     // attribute regs ar[0..0x14] (0x15 = VGA_ATT_C)

    logic [7:0]  msr;            // misc output register
    logic [7:0]  fcr;            // feature control register
    logic [7:0]  st00;           // input status 0 (read-only here, stays reset)
    logic [7:0]  st01;           // input status 1 (toggles on IS1 read)

    logic [2:0]  sr_index;       // sequencer index (val & 7)
    logic [7:0]  sr  [0:7];      // sequencer regs

    logic [3:0]  gr_index;       // graphics index (val & 0x0f)
    logic [7:0]  gr  [0:15];     // graphics regs

    logic [7:0]  cr_index;       // CRTC index (full 8 bits in QEMU)
    logic [7:0]  cr  [0:255];    // CRTC regs

    logic [7:0]  dac_state;      // PEL state: 0 after write-index, 3 after read-index
    logic [1:0]  dac_sub_index;  // 0/1/2 -> R/G/B sub-byte
    logic [7:0]  dac_read_index; // PEL read index
    logic [7:0]  dac_write_index;// PEL write index
    logic [7:0]  dac_cache [0:2];// 3-byte write staging cache
    logic [7:0]  palette [0:767];// 256 * 3 = 768-byte palette

    integer i;

    // ---- Per-index write masks (sr_mask / gr_mask from vga.c) -------------
    function automatic logic [7:0] sr_mask(input logic [2:0] idx);
        case (idx)
            3'd0: sr_mask = 8'h03;
            3'd1: sr_mask = 8'h3d;
            3'd2: sr_mask = 8'h0f;
            3'd3: sr_mask = 8'h3f;
            3'd4: sr_mask = 8'h0e;
            3'd5: sr_mask = 8'h00;
            3'd6: sr_mask = 8'h00;
            3'd7: sr_mask = 8'hff;
            default: sr_mask = 8'h00;
        endcase
    endfunction

    function automatic logic [7:0] gr_mask(input logic [3:0] idx);
        case (idx)
            4'h0: gr_mask = 8'h0f;
            4'h1: gr_mask = 8'h0f;
            4'h2: gr_mask = 8'h0f;
            4'h3: gr_mask = 8'h1f;
            4'h4: gr_mask = 8'h03;
            4'h5: gr_mask = 8'h7b;
            4'h6: gr_mask = 8'h0f;
            4'h7: gr_mask = 8'h0f;
            4'h8: gr_mask = 8'hff;
            default: gr_mask = 8'h00; // 0x09..0x0f
        endcase
    endfunction

    // ---- Attribute-register per-index write mask (vga.c lines 457-478) ----
    // Returns the masked value to store; index is ar_index & 0x1f.
    function automatic logic [7:0] ar_write_val(input logic [4:0] idx,
                                                input logic [7:0] val);
        if (idx <= 5'h0F)       ar_write_val = val & 8'h3f;        // PALETTE0..F
        else if (idx == 5'h10)  ar_write_val = val & ~8'h10;       // ATC_MODE
        else if (idx == 5'h11)  ar_write_val = val;                // ATC_OVERSCAN
        else if (idx == 5'h12)  ar_write_val = val & ~8'hc0;       // PLANE_ENABLE
        else if (idx == 5'h13)  ar_write_val = val & ~8'hf0;       // ATC_PEL
        else if (idx == 5'h14)  ar_write_val = val & ~8'hf0;       // COLOR_PAGE
        else                    ar_write_val = val;                // default (>0x14): unused
    endfunction

    // ---- Color/mono port validity (vga_ioport_invalid, vga.c line 338) ----
    // msr bit0 set => COLOR mode => 0x3b0..0x3bf invalid.
    //              clear => MONO mode => 0x3d0..0x3df invalid.
    function automatic logic port_invalid(input logic [15:0] a);
        if (msr[0])  // VGA_MIS_COLOR
            port_invalid = (a >= 16'h3b0) && (a <= 16'h3bf);
        else
            port_invalid = (a >= 16'h3d0) && (a <= 16'h3df);
    endfunction

    // ---- Helper index aliases (combinational) -----------------------------
    wire [4:0] ar_idx5  = ar_index[4:0];          // ar_index & 0x1f

    // ============================================================================
    // COMBINATIONAL READ  (rdata = addressed register; side-effects are clocked)
    // ============================================================================
    // palette read address = dac_read_index*3 + dac_sub_index
    logic [9:0] pal_read_addr;
    always_comb begin
        pal_read_addr = ({2'b0, dac_read_index} * 10'd3) + {8'b0, dac_sub_index};
    end

    always_comb begin
        rdata = 8'h00;
        if (port_invalid(addr)) begin
            rdata = 8'hff;
        end else begin
            unique case (addr)
                VGA_ATT_W:  rdata = (ar_flip_flop == 1'b0) ? {2'b0, ar_index} : 8'h00;
                VGA_ATT_R:  rdata = (ar_idx5 < VGA_ATT_C) ? ar[ar_idx5] : 8'h00;
                VGA_MIS_W:  rdata = st00;                       // read 0x3c2 -> st00
                VGA_SEQ_I:  rdata = {5'b0, sr_index};
                VGA_SEQ_D:  rdata = sr[sr_index];
                VGA_PEL_IR: rdata = dac_state;                  // read 0x3c7 -> dac_state
                VGA_PEL_IW: rdata = dac_write_index;            // read 0x3c8 -> write index
                VGA_PEL_D:  rdata = palette[pal_read_addr];     // read palette[read*3+sub]
                VGA_FTC_R:  rdata = fcr;
                VGA_MIS_R:  rdata = msr;
                VGA_GFX_I:  rdata = {4'b0, gr_index};
                VGA_GFX_D:  rdata = gr[gr_index];
                VGA_CRT_IC,
                VGA_CRT_IM: rdata = cr_index;
                VGA_CRT_DC,
                VGA_CRT_DM: rdata = cr[cr_index];
                VGA_IS1_RC,
                VGA_IS1_RM: rdata = st01 ^ ST01_TOGGLE;         // dumb retrace toggle value
                default:    rdata = 8'h00;
            endcase
        end
    end

    // ============================================================================
    // CLOCKED STATE  (writes when cs&we; read side-effects when cs&~we)
    // ============================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            // vga_common_reset() (vga.c line 1810): all regs/state cleared.
            ar_index        <= 6'd0;
            ar_flip_flop    <= 1'b0;
            for (i = 0; i <= 20; i = i + 1)  ar[i]  <= 8'h00;
            msr             <= 8'h00;
            fcr             <= 8'h00;
            st00            <= 8'h00;
            st01            <= 8'h00;
            sr_index        <= 3'd0;
            for (i = 0; i <= 7;  i = i + 1)  sr[i]  <= 8'h00;
            gr_index        <= 4'd0;
            for (i = 0; i <= 15; i = i + 1)  gr[i]  <= 8'h00;
            cr_index        <= 8'h00;
            for (i = 0; i <= 255;i = i + 1)  cr[i]  <= 8'h00;
            dac_state       <= 8'h00;
            dac_sub_index   <= 2'd0;
            dac_read_index  <= 8'h00;
            dac_write_index <= 8'h00;
            dac_cache[0]    <= 8'h00;
            dac_cache[1]    <= 8'h00;
            dac_cache[2]    <= 8'h00;
            for (i = 0; i <= 767;i = i + 1)  palette[i] <= 8'h00;
        end else if (cs && !port_invalid(addr)) begin
            // ---------------------------------------------------------------
            if (we) begin
                // ====================== CPU WRITE (OUT) ====================
                unique case (addr)
                    // ---- ATTRIBUTE (0x3c0): toggling index/data port -------
                    VGA_ATT_W: begin
                        if (ar_flip_flop == 1'b0) begin
                            ar_index <= wdata[5:0];             // val & 0x3f
                        end else begin
                            // data phase: write ar[ar_index & 0x1f] (only if <0x15
                            // is meaningful; QEMU's switch only stores idx 0..0x14)
                            if (ar_idx5 <= 5'h14)
                                ar[ar_idx5] <= ar_write_val(ar_idx5, wdata);
                        end
                        ar_flip_flop <= ~ar_flip_flop;          // toggle each write
                    end

                    // ---- MISC OUTPUT (0x3c2) -------------------------------
                    VGA_MIS_W: begin
                        msr <= wdata & ~8'h10;                  // val & ~0x10
                    end

                    // ---- SEQUENCER -----------------------------------------
                    VGA_SEQ_I: sr_index <= wdata[2:0];          // val & 7
                    VGA_SEQ_D: sr[sr_index] <= wdata & sr_mask(sr_index);

                    // ---- DAC -----------------------------------------------
                    VGA_PEL_IR: begin                            // read index write
                        dac_read_index <= wdata;
                        dac_sub_index  <= 2'd0;
                        dac_state      <= 8'd3;
                    end
                    VGA_PEL_IW: begin                            // write index write
                        dac_write_index <= wdata;
                        dac_sub_index   <= 2'd0;
                        dac_state       <= 8'd0;
                    end
                    VGA_PEL_D: begin                             // palette data write
                        dac_cache[dac_sub_index] <= wdata;
                        if (dac_sub_index == 2'd2) begin
                            // commit 3-byte cache to palette[write_index*3 .. +2]
                            // bytes 0,1 from cache, byte 2 is wdata just received.
                            palette[({2'b0,dac_write_index}*10'd3) + 10'd0] <= dac_cache[0];
                            palette[({2'b0,dac_write_index}*10'd3) + 10'd1] <= dac_cache[1];
                            palette[({2'b0,dac_write_index}*10'd3) + 10'd2] <= wdata;
                            dac_sub_index   <= 2'd0;
                            dac_write_index <= dac_write_index + 8'd1;
                        end else begin
                            dac_sub_index <= dac_sub_index + 2'd1;
                        end
                    end

                    // ---- GRAPHICS ------------------------------------------
                    VGA_GFX_I: gr_index <= wdata[3:0];          // val & 0x0f
                    VGA_GFX_D: gr[gr_index] <= wdata & gr_mask(gr_index);

                    // ---- CRTC ----------------------------------------------
                    VGA_CRT_IC, VGA_CRT_IM: cr_index <= wdata;  // full 8 bits
                    VGA_CRT_DC, VGA_CRT_DM: begin
                        // CR0-7 protection: if CR11 bit7 set and idx<=CR7, locked,
                        // except CR7 bit4 is always writable.
                        if ((cr[VGA_CRTC_V_SYNC_END] & VGA_CR11_LOCK) != 8'h00 &&
                            cr_index <= VGA_CRTC_OVERFLOW) begin
                            if (cr_index == VGA_CRTC_OVERFLOW) begin
                                // CR7: only bit4 writable
                                cr[VGA_CRTC_OVERFLOW] <=
                                    (cr[VGA_CRTC_OVERFLOW] & ~8'h10) | (wdata & 8'h10);
                            end
                            // else: write fully ignored (locked)
                        end else begin
                            cr[cr_index] <= wdata;
                        end
                    end

                    // ---- INPUT STATUS 1 write (3da/3ba) -> feature control --
                    VGA_IS1_RC, VGA_IS1_RM: fcr <= wdata & 8'h10; // val & 0x10
                    default: ;
                endcase
            end else begin
                // ====================== CPU READ (IN) ======================
                // Reads with state-mutating side effects commit here.
                unique case (addr)
                    VGA_PEL_D: begin
                        // DAC palette read auto-increment: ++sub; wrap at 3 -> read++
                        if (dac_sub_index == 2'd2) begin
                            dac_sub_index  <= 2'd0;
                            dac_read_index <= dac_read_index + 8'd1;
                        end else begin
                            dac_sub_index <= dac_sub_index + 2'd1;
                        end
                    end
                    VGA_IS1_RC, VGA_IS1_RM: begin
                        // dumb retrace: st01 toggles bits 0x09; resets attr ff.
                        st01         <= st01 ^ ST01_TOGGLE;
                        ar_flip_flop <= 1'b0;
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---- M8.6: live mode bits for ven_vga_fb (combinational off the regs) ----
    assign o_seq_plane_mask = sr[2];
    assign o_seq_mem_mode   = sr[4];
    assign o_gfx_mode       = gr[5];
    assign o_gfx_misc       = gr[6];

endmodule
