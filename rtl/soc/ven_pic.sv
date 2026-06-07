// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// ven_pic.sv  --  Intel 8259A Programmable Interrupt Controller (cascaded pair)
//
//   Ventium SoC (M8) PC-peripheral device.  STANDALONE, SYNTHESIZABLE.
//
//   Models the standard PC/AT dual-8259A:
//     * Master 8259A : I/O ports 0x20 (cmd) / 0x21 (data)
//     * Slave  8259A : I/O ports 0xA0 (cmd) / 0xA1 (data)
//     * ELCR         : I/O ports 0x4D0 (master) / 0x4D1 (slave)
//   The slave INT output is cascaded onto the master IR2.
//
//   Behaviour is matched bit-for-bit to QEMU 8.2.2 hw/intc/i8259.c +
//   i8259_common.c (the authoritative reference for the later
//   differential-vs-qemu-system SoC gate):
//       get_priority(), pic_get_irq(), pic_update_irq(), pic_set_irq(),
//       pic_intack(), pic_read_irq(), pic_ioport_write/read(),
//       elcr_ioport_write/read(), pic_reset()/pic_reset_common().
//
//   Per-chip state (master + slave each):
//     irr, imr, isr, last_irr, priority_add, irq_base,
//     read_reg_select, poll, special_mask, init_state, auto_eoi,
//     rotate_on_auto_eoi, special_fully_nested_mode (sfnm),
//     init4, single_mode, elcr, ltim.
//
//   Register interface follows the SoC common contract:
//     - writes commit on the clocked edge when (cs & we)
//     - reads are COMBINATIONAL off the registers; read side-effects
//       (poll-mode intack) commit on the clocked edge when (cs & ~we)
//     - rst is SYNCHRONOUS, ACTIVE-HIGH (PC RESET)
// ============================================================================
`default_nettype none

module ven_pic (
    input  wire logic        clk,
    input  wire logic        rst,          // synchronous, active-high (PC RESET)

    // ---- SoC common register interface -------------------------------------
    input  wire logic        cs,           // chip-select (decoder asserts on our ports)
    input  wire logic        we,           // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  wire logic [15:0] addr,         // I/O port address
    input  wire logic [7:0]  wdata,        // write data
    output logic [7:0]  rdata,        // read data (combinational off regs)

    // ---- PIC-specific interface --------------------------------------------
    input  wire logic [15:0] irq_in,       // device IRQ lines IR0..IR15 (levels)
    output logic        int_out,      // -> core INTR
    input  wire logic        inta,         // 1-clk interrupt-acknowledge strobe
    output logic [7:0]  inta_vector   // vector returned for this acknowledge
);

    // ------------------------------------------------------------------------
    // Port address constants
    // ------------------------------------------------------------------------
    localparam logic [15:0] PORT_M_CMD  = 16'h0020; // master cmd  (addr bit0=0)
    localparam logic [15:0] PORT_M_DATA = 16'h0021; // master data (addr bit0=1)
    localparam logic [15:0] PORT_S_CMD  = 16'h00A0; // slave  cmd
    localparam logic [15:0] PORT_S_DATA = 16'h00A1; // slave  data
    localparam logic [15:0] PORT_ELCR_M = 16'h04D0; // ELCR master
    localparam logic [15:0] PORT_ELCR_S = 16'h04D1; // ELCR slave

    // ELCR write masks (QEMU i8259_init_chip): master 0xf8, slave 0xde.
    localparam logic [7:0]  ELCR_MASK_M = 8'hF8;
    localparam logic [7:0]  ELCR_MASK_S = 8'hDE;

    // ------------------------------------------------------------------------
    // Per-chip state, indexed [0]=master, [1]=slave
    // ------------------------------------------------------------------------
    logic [7:0] irr      [0:1];
    logic [7:0] imr      [0:1];
    logic [7:0] isr      [0:1];
    logic [7:0] last_irr [0:1];
    logic [2:0] prio_add [0:1];   // priority_add (0..7)
    logic [7:0] irq_base [0:1];
    logic       rr_sel   [0:1];   // read_reg_select (0=IRR,1=ISR)
    logic       poll     [0:1];
    logic       spec_mask[0:1];   // special_mask
    logic [1:0] init_st  [0:1];   // init_state (0..3)
    logic       auto_eoi [0:1];
    logic       rot_aeoi [0:1];   // rotate_on_auto_eoi
    logic       sfnm     [0:1];   // special_fully_nested_mode
    logic       init4    [0:1];
    logic       single_md[0:1];   // single_mode
    logic [7:0] elcr     [0:1];
    logic       ltim     [0:1];

    // master = chip 0, slave = chip 1 (1-bit chip index)
    localparam bit M = 1'b0;
    localparam bit S = 1'b1;

    // ========================================================================
    //  Combinational helpers (mirror the QEMU static functions)
    // ========================================================================

    // get_priority(s, mask): highest priority in mask, 8 if none.
    // highest = smallest ((p + priority_add) & 7).
    function automatic logic [3:0] get_priority(input logic [7:0] mask,
                                                input logic [2:0] padd);
        logic [3:0] p;
        begin
            if (mask == 8'h00) begin
                get_priority = 4'd8;
            end else begin
                // Smallest p in 0..7 such that bit ((p+padd)&7) of mask is set
                // (mask != 0 guarantees a hit). A while-loop with a runtime
                // condition is not statically unrollable by Vivado synth, so use
                // a bounded for with a found-flag (semantics identical).
                p = 4'd0;
                begin
                    logic found;
                    found = 1'b0;
                    for (int k = 0; k < 8; k++) begin
                        if (!found &&
                            (mask & (8'h01 << ((k[2:0] + padd) & 3'h7))) != 8'h00) begin
                            p = k[3:0];
                            found = 1'b1;
                        end
                    end
                end
                get_priority = p;
            end
        end
    endfunction

    // pic_get_irq(s): the IRQ the chip wants to deliver, -1 (==4'd8 here) if none.
    //   ci : chip index (M or S).  Returns 0..7, or 8 meaning "none".
    function automatic logic [3:0] pic_get_irq(input bit ci);
        logic [7:0] mask;
        logic [3:0] prio;
        logic [3:0] cur_prio;
        begin
            mask = irr[ci] & ~imr[ci];
            prio = get_priority(mask, prio_add[ci]);
            if (prio == 4'd8) begin
                pic_get_irq = 4'd8;
            end else begin
                // current in-service priority
                mask = isr[ci];
                if (spec_mask[ci])
                    mask = mask & ~imr[ci];
                if (sfnm[ci] && (ci == M))
                    mask = mask & ~(8'h01 << 2);  // ignore cascade IR2
                cur_prio = get_priority(mask, prio_add[ci]);
                if (prio < cur_prio)
                    pic_get_irq = {1'b0, (prio[2:0] + prio_add[ci]) & 3'h7};
                else
                    pic_get_irq = 4'd8;
            end
        end
    endfunction

    // pic_get_output(s): does this chip currently want to interrupt?
    function automatic logic pic_get_output(input bit ci);
        begin
            pic_get_output = (pic_get_irq(ci) != 4'd8);
        end
    endfunction

    // int_out -> core: master output, exactly QEMU pic_update_irq on the master.
    assign int_out = pic_get_output(M);

    // ========================================================================
    //  Combinational READ data (off the registers + read-side-effects shown)
    //    Matches pic_ioport_read / elcr_ioport_read.
    //    Poll-mode read returns (irq | 0x80) or 0; the intack side-effect is
    //    applied on the clocked edge below.
    // ========================================================================
    function automatic logic [7:0] read_chip(input bit ci, input logic data_port);
        logic [3:0] irq;
        begin
            if (poll[ci]) begin
                irq = pic_get_irq(ci);
                if (irq != 4'd8)
                    read_chip = {1'b1, 4'h0, irq[2:0]}; // irq | 0x80
                else
                    read_chip = 8'h00;
            end else begin
                if (!data_port) begin
                    read_chip = rr_sel[ci] ? isr[ci] : irr[ci];
                end else begin
                    read_chip = imr[ci];
                end
            end
        end
    endfunction

    always_comb begin
        rdata = 8'h00;
        unique case (addr)
            PORT_M_CMD : rdata = read_chip(M, 1'b0);
            PORT_M_DATA: rdata = read_chip(M, 1'b1);
            PORT_S_CMD : rdata = read_chip(S, 1'b0);
            PORT_S_DATA: rdata = read_chip(S, 1'b1);
            PORT_ELCR_M: rdata = elcr[M];
            PORT_ELCR_S: rdata = elcr[S];
            default    : rdata = 8'h00;
        endcase
    end

    // ========================================================================
    //  inta_vector : combinationally compute the vector that pic_read_irq()
    //  would return for the master, given current state.  The state mutation
    //  (intack: set ISR / clear IRR / advance prio) is applied on the clocked
    //  edge when `inta` strobes (see sequential block).  This mirrors QEMU's
    //  pic_read_irq() which both returns the vector AND performs pic_intack.
    // ========================================================================
    logic [3:0] m_irq_w;       // master pic_get_irq
    logic [3:0] s_irq_w;       // slave  pic_get_irq (only if m_irq==2)

    always_comb begin
        m_irq_w     = pic_get_irq(M);
        s_irq_w     = 4'd8;
        inta_vector = 8'h00;

        if (m_irq_w != 4'd8) begin
            if (m_irq_w == 4'd2) begin
                s_irq_w = pic_get_irq(S);
                if (s_irq_w != 4'd8) begin
                    inta_vector = irq_base[S] + {5'h0, s_irq_w[2:0]};
                end else begin
                    inta_vector = irq_base[S] + 8'd7;  // spurious slave -> IR7
                end
            end else begin
                inta_vector = irq_base[M] + {5'h0, m_irq_w[2:0]};
            end
        end else begin
            // spurious IRQ on master -> IR7
            inta_vector = irq_base[M] + 8'd7;
        end
    end

    // ------------------------------------------------------------------------
    //  Decode of the current bus access (only meaningful when cs asserted)
    // ------------------------------------------------------------------------
    logic acc_m_cmd, acc_m_data, acc_s_cmd, acc_s_data, acc_elcr_m, acc_elcr_s;
    always_comb begin
        acc_m_cmd  = (addr == PORT_M_CMD);
        acc_m_data = (addr == PORT_M_DATA);
        acc_s_cmd  = (addr == PORT_S_CMD);
        acc_s_data = (addr == PORT_S_DATA);
        acc_elcr_m = (addr == PORT_ELCR_M);
        acc_elcr_s = (addr == PORT_ELCR_S);
    end

    // ========================================================================
    //  Sequential update
    // ========================================================================
    integer ci;

    // next-state working copies (so set_irq / write / inta can compose in order
    // matching QEMU's call sequence within a single emulated step)
    logic [7:0] n_irr      [0:1];
    logic [7:0] n_imr      [0:1];
    logic [7:0] n_isr      [0:1];
    logic [7:0] n_last_irr [0:1];
    logic [2:0] n_prio_add [0:1];
    logic [7:0] n_irq_base [0:1];
    logic       n_rr_sel   [0:1];
    logic       n_poll     [0:1];
    logic       n_spec_mask[0:1];
    logic [1:0] n_init_st  [0:1];
    logic       n_auto_eoi [0:1];
    logic       n_rot_aeoi [0:1];
    logic       n_sfnm     [0:1];
    logic       n_init4    [0:1];
    logic       n_single_md[0:1];
    logic [7:0] n_elcr     [0:1];
    logic       n_ltim     [0:1];

    // local task-style helpers operating on next-state arrays ----------------

    // apply pic_intack() to chip ci for irq (matches QEMU pic_intack)
    function automatic void do_intack(input bit ci_, input logic [2:0] irq_);
        begin
            if (n_auto_eoi[ci_]) begin
                if (n_rot_aeoi[ci_])
                    n_prio_add[ci_] = (irq_ + 3'd1) & 3'h7;
            end else begin
                n_isr[ci_] = n_isr[ci_] | (8'h01 << irq_);
            end
            // don't clear a level-sensitive interrupt
            if (!n_ltim[ci_] && ((n_elcr[ci_] & (8'h01 << irq_)) == 8'h00))
                n_irr[ci_] = n_irr[ci_] & ~(8'h01 << irq_);
        end
    endfunction

    // init-reset (ICW1 path): pic_init_reset -> pic_reset_common, but NOT elcr/ltim
    function automatic void do_init_reset(input bit ci_);
        begin
            n_last_irr[ci_]  = 8'h00;
            n_irr[ci_]       = n_irr[ci_] & n_elcr[ci_]; // irr &= elcr
            n_imr[ci_]       = 8'h00;
            n_isr[ci_]       = 8'h00;
            n_prio_add[ci_]  = 3'd0;
            n_irq_base[ci_]  = 8'h00;
            n_rr_sel[ci_]    = 1'b0;
            n_poll[ci_]      = 1'b0;
            n_spec_mask[ci_] = 1'b0;
            n_init_st[ci_]   = 2'd0;
            n_auto_eoi[ci_]  = 1'b0;
            n_rot_aeoi[ci_]  = 1'b0;
            n_sfnm[ci_]      = 1'b0;
            n_init4[ci_]     = 1'b0;
            n_single_md[ci_] = 1'b0;
        end
    endfunction

    // one OCW2/OCW3/ICW command-port write to chip ci (val) -- pic_ioport_write addr==0
    function automatic void wr_cmd(input bit ci_, input logic [7:0] val);
        logic [3:0] prio;
        logic [2:0] irqn;
        logic [2:0] cmd;
        begin
            if (val[4]) begin
                // ICW1
                do_init_reset(ci_);
                n_init_st[ci_]   = 2'd1;
                n_init4[ci_]     = val[0];
                n_single_md[ci_] = val[1];
                n_ltim[ci_]      = val[3];
            end else if (val[3]) begin
                // OCW3
                if (val[2]) n_poll[ci_]     = 1'b1;
                if (val[1]) n_rr_sel[ci_]    = val[0];
                if (val[6]) n_spec_mask[ci_] = val[5];
            end else begin
                // OCW2
                cmd = val[7:5];
                unique case (cmd)
                    3'd0, 3'd4: begin
                        n_rot_aeoi[ci_] = cmd[2];
                    end
                    3'd1, 3'd5: begin // (rotate on) non-specific EOI
                        prio = get_priority(n_isr[ci_], n_prio_add[ci_]);
                        if (prio != 4'd8) begin
                            irqn = (prio[2:0] + n_prio_add[ci_]) & 3'h7;
                            n_isr[ci_] = n_isr[ci_] & ~(8'h01 << irqn);
                            if (cmd == 3'd5)
                                n_prio_add[ci_] = (irqn + 3'd1) & 3'h7;
                        end
                    end
                    3'd3: begin // specific EOI
                        irqn = val[2:0];
                        n_isr[ci_] = n_isr[ci_] & ~(8'h01 << irqn);
                    end
                    3'd6: begin // set priority (rotate)
                        n_prio_add[ci_] = (val[2:0] + 3'd1) & 3'h7;
                    end
                    3'd7: begin // rotate on specific EOI
                        irqn = val[2:0];
                        n_isr[ci_] = n_isr[ci_] & ~(8'h01 << irqn);
                        n_prio_add[ci_] = (irqn + 3'd1) & 3'h7;
                    end
                    default: ; // no operation
                endcase
            end
        end
    endfunction

    // one data-port write to chip ci (val) -- pic_ioport_write addr==1
    function automatic void wr_data(input bit ci_, input logic [7:0] val);
        begin
            unique case (n_init_st[ci_])
                2'd0: begin // normal: OCW1 = IMR
                    n_imr[ci_] = val;
                end
                2'd1: begin // ICW2: vector base
                    n_irq_base[ci_] = val & 8'hF8;
                    n_init_st[ci_]  = n_single_md[ci_] ? (n_init4[ci_] ? 2'd3 : 2'd0)
                                                       : 2'd2;
                end
                2'd2: begin // ICW3 (cascade) -- value ignored functionally
                    n_init_st[ci_] = n_init4[ci_] ? 2'd3 : 2'd0;
                end
                2'd3: begin // ICW4
                    n_sfnm[ci_]     = val[4];
                    n_auto_eoi[ci_] = val[1];
                    n_init_st[ci_]  = 2'd0;
                end
                default: ;
            endcase
        end
    endfunction

    // set/clear an IRQ line on chip ci (pic_set_irq), with edge detection.
    function automatic void set_irq(input bit ci_, input logic [2:0] irqn,
                                    input logic level);
        logic [7:0] mask;
        begin
            mask = 8'h01 << irqn;
            if (n_ltim[ci_] || ((n_elcr[ci_] & mask) != 8'h00)) begin
                // level triggered
                if (level) begin
                    n_irr[ci_]      = n_irr[ci_]      | mask;
                    n_last_irr[ci_] = n_last_irr[ci_] | mask;
                end else begin
                    n_irr[ci_]      = n_irr[ci_]      & ~mask;
                    n_last_irr[ci_] = n_last_irr[ci_] & ~mask;
                end
            end else begin
                // edge triggered
                if (level) begin
                    if ((n_last_irr[ci_] & mask) == 8'h00)
                        n_irr[ci_] = n_irr[ci_] | mask;
                    n_last_irr[ci_] = n_last_irr[ci_] | mask;
                end else begin
                    n_last_irr[ci_] = n_last_irr[ci_] & ~mask;
                end
            end
        end
    endfunction

    // The n_* next-state working variables are intentionally updated with
    // blocking assignments so that the QEMU per-step mutation sequence
    // (set_irq -> write -> read-side-effect -> intack) composes in order
    // before being committed (non-blocking) to the real state registers.
    /* verilator lint_off BLKSEQ */
    always_ff @(posedge clk) begin
        if (rst) begin
            // pic_reset(): elcr=0, ltim=0, then pic_init_reset->pic_reset_common.
            for (ci = 0; ci < 2; ci = ci + 1) begin
                elcr[ci]      <= 8'h00;
                ltim[ci]      <= 1'b0;
                last_irr[ci]  <= 8'h00;
                irr[ci]       <= 8'h00;  // irr &= elcr, elcr just zeroed -> 0
                imr[ci]       <= 8'h00;
                isr[ci]       <= 8'h00;
                prio_add[ci]  <= 3'd0;
                irq_base[ci]  <= 8'h00;
                rr_sel[ci]    <= 1'b0;
                poll[ci]      <= 1'b0;
                spec_mask[ci] <= 1'b0;
                init_st[ci]   <= 2'd0;
                auto_eoi[ci]  <= 1'b0;
                rot_aeoi[ci]  <= 1'b0;
                sfnm[ci]      <= 1'b0;
                init4[ci]     <= 1'b0;
                single_md[ci] <= 1'b0;
            end
        end else begin
            // ---- load next-state working copies from current state ----------
            for (ci = 0; ci < 2; ci = ci + 1) begin
                n_irr[ci]       = irr[ci];
                n_imr[ci]       = imr[ci];
                n_isr[ci]       = isr[ci];
                n_last_irr[ci]  = last_irr[ci];
                n_prio_add[ci]  = prio_add[ci];
                n_irq_base[ci]  = irq_base[ci];
                n_rr_sel[ci]    = rr_sel[ci];
                n_poll[ci]      = poll[ci];
                n_spec_mask[ci] = spec_mask[ci];
                n_init_st[ci]   = init_st[ci];
                n_auto_eoi[ci]  = auto_eoi[ci];
                n_rot_aeoi[ci]  = rot_aeoi[ci];
                n_sfnm[ci]      = sfnm[ci];
                n_init4[ci]     = init4[ci];
                n_single_md[ci] = single_md[ci];
                n_elcr[ci]      = elcr[ci];
                n_ltim[ci]      = ltim[ci];
            end

            // ---- (1) sample external IRQ lines and run set_irq edge logic ----
            // Master IR2 is the cascade from the slave and is driven internally
            // (by the slave's output), NOT by irq_in[2]; QEMU wires slave INT to
            // master IR2.  We sample irq_in[7:0] for master IR0..IR7 EXCEPT IR2,
            // and irq_in[15:8] for the slave IR0..IR7.
            for (int b = 0; b < 8; b = b + 1) begin
                if (b != 2)
                    set_irq(M, b[2:0], irq_in[b]);
                set_irq(S, b[2:0], irq_in[8 + b]);
            end
            // cascade: drive master IR2 from slave output level (pic_get_output).
            // QEMU models the slave INT line as a level into master IR2 (edge
            // logic on a non-ELCR line). Reproduce by treating it as the slave's
            // current "wants interrupt" level via set_irq on master IR2.
            set_irq(M, 3'd2, pic_get_output_next(S));

            // ---- (2) register WRITE (cs & we) on this clocked edge ----------
            if (cs && we) begin
                if      (acc_m_cmd ) wr_cmd (M, wdata);
                else if (acc_m_data) wr_data(M, wdata);
                else if (acc_s_cmd ) wr_cmd (S, wdata);
                else if (acc_s_data) wr_data(S, wdata);
                else if (acc_elcr_m) n_elcr[M] = wdata & ELCR_MASK_M;
                else if (acc_elcr_s) n_elcr[S] = wdata & ELCR_MASK_S;
            end

            // ---- (3) READ side-effects (cs & ~we): poll-mode intack ---------
            if (cs && !we) begin
                // poll-mode read consumes the IRQ (pic_intack) then clears poll.
                if (acc_m_cmd || acc_m_data) begin
                    if (n_poll[M]) begin
                        logic [3:0] irqp;
                        irqp = pic_get_irq_next(M);
                        if (irqp != 4'd8) do_intack(M, irqp[2:0]);
                        n_poll[M] = 1'b0;
                    end
                end
                if (acc_s_cmd || acc_s_data) begin
                    if (n_poll[S]) begin
                        logic [3:0] irqp;
                        irqp = pic_get_irq_next(S);
                        if (irqp != 4'd8) do_intack(S, irqp[2:0]);
                        n_poll[S] = 1'b0;
                    end
                end
            end

            // ---- (4) INTA strobe : pic_read_irq() side-effects --------------
            if (inta) begin
                logic [3:0] mi;
                logic [3:0] si;
                mi = pic_get_irq_next(M);
                if (mi != 4'd8) begin
                    if (mi == 4'd2) begin
                        si = pic_get_irq_next(S);
                        if (si != 4'd8) do_intack(S, si[2:0]);
                        // (spurious slave -> 7, no slave intack, per QEMU)
                        do_intack(M, 3'd2);
                    end else begin
                        do_intack(M, mi[2:0]);
                    end
                end
                // spurious master (mi==8): no intack, vector already = base+7
            end

            // ---- commit next-state ------------------------------------------
            for (ci = 0; ci < 2; ci = ci + 1) begin
                irr[ci]       <= n_irr[ci];
                imr[ci]       <= n_imr[ci];
                isr[ci]       <= n_isr[ci];
                last_irr[ci]  <= n_last_irr[ci];
                prio_add[ci]  <= n_prio_add[ci];
                irq_base[ci]  <= n_irq_base[ci];
                rr_sel[ci]    <= n_rr_sel[ci];
                poll[ci]      <= n_poll[ci];
                spec_mask[ci] <= n_spec_mask[ci];
                init_st[ci]   <= n_init_st[ci];
                auto_eoi[ci]  <= n_auto_eoi[ci];
                rot_aeoi[ci]  <= n_rot_aeoi[ci];
                sfnm[ci]      <= n_sfnm[ci];
                init4[ci]     <= n_init4[ci];
                single_md[ci] <= n_single_md[ci];
                elcr[ci]      <= n_elcr[ci];
                ltim[ci]      <= n_ltim[ci];
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    // ------------------------------------------------------------------------
    //  next-state versions of the combinational helpers (operate on n_* arrays)
    //  Needed because (1) the cascade level and (4) inta must observe the IRR
    //  updates already applied within the same clocked step, matching QEMU's
    //  in-order pic_update_irq calls.
    // ------------------------------------------------------------------------
    function automatic logic [3:0] pic_get_irq_next(input bit cx);
        logic [7:0] mask;
        logic [3:0] prio;
        logic [3:0] cur_prio;
        begin
            mask = n_irr[cx] & ~n_imr[cx];
            prio = get_priority(mask, n_prio_add[cx]);
            if (prio == 4'd8) begin
                pic_get_irq_next = 4'd8;
            end else begin
                mask = n_isr[cx];
                if (n_spec_mask[cx]) mask = mask & ~n_imr[cx];
                if (n_sfnm[cx] && (cx == M)) mask = mask & ~(8'h01 << 2);
                cur_prio = get_priority(mask, n_prio_add[cx]);
                if (prio < cur_prio)
                    pic_get_irq_next = {1'b0, (prio[2:0] + n_prio_add[cx]) & 3'h7};
                else
                    pic_get_irq_next = 4'd8;
            end
        end
    endfunction

    function automatic logic pic_get_output_next(input bit cx);
        begin
            pic_get_output_next = (pic_get_irq_next(cx) != 4'd8);
        end
    endfunction

endmodule

`default_nettype wire
