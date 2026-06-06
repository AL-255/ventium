// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// tb_ven_vgaregs.sv -- directed unit self-check for ven_vgaregs (M8, VGA regfile)
//
// This is a UNIT-LEVEL self-check vs the DOCUMENTED QEMU 8.2.2 register
// semantics (hw/display/vga.c) -- NOT yet differential-vs-qemu-system (that
// comes at SoC integration). It drives the common ven_* register interface
// through the documented OUT/IN sequences and asserts CPU-observable results.
//
// Interface contract exercised:
//   - WRITES commit on the clocked edge when (cs & we).
//   - READS are combinational on rdata; read side-effects (DAC auto-increment,
//     IS1 retrace toggle + attr-ff reset) commit on the clocked edge (cs & ~we).
//   - rst is synchronous active-high.
// ============================================================================
`timescale 1ns/1ps

module tb_ven_vgaregs;

    logic        clk;
    logic        rst;
    logic        cs;
    logic        we;
    logic [15:0] addr;
    logic [7:0]  wdata;
    logic [7:0]  rdata;

    ven_vgaregs dut (
        .clk(clk), .rst(rst), .cs(cs), .we(we),
        .addr(addr), .wdata(wdata), .rdata(rdata)
    );

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    // ---- helpers ----------------------------------------------------------
    // OUT (CPU write): present cs/we/addr/wdata, commit on a posedge.
    task automatic io_out(input logic [15:0] a, input logic [7:0] d);
        begin
            @(negedge clk);
            cs = 1'b1; we = 1'b1; addr = a; wdata = d;
            @(posedge clk);              // write commits here
            @(negedge clk);
            cs = 1'b0; we = 1'b0; wdata = 8'h00;
        end
    endtask

    // IN (CPU read) WITHOUT advancing a clock edge: sample combinational rdata.
    // Use this to read a register without triggering a clocked read side-effect.
    task automatic io_peek(input logic [15:0] a, output logic [7:0] d);
        begin
            @(negedge clk);
            cs = 1'b0; we = 1'b0; addr = a;     // cs low: pure combinational peek
            #1;
            d = rdata;
        end
    endtask

    // IN (CPU read) WITH the clocked read side-effect applied (cs asserted over
    // a posedge). rdata is sampled combinationally just before the edge.
    task automatic io_in(input logic [15:0] a, output logic [7:0] d);
        begin
            @(negedge clk);
            cs = 1'b1; we = 1'b0; addr = a;
            #1;
            d = rdata;                   // value the CPU latches this cycle
            @(posedge clk);              // read side-effect commits here
            @(negedge clk);
            cs = 1'b0;
        end
    endtask

    task automatic chk(input string name, input logic [7:0] got, input logic [7:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %-40s got=0x%02x exp=0x%02x", name, got, exp);
            end else begin
                $display("  [PASS] %-40s = 0x%02x", name, got);
            end
        end
    endtask

    task automatic do_reset();
        begin
            cs = 0; we = 0; addr = 0; wdata = 0;
            rst = 1'b1;
            @(posedge clk); @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    logic [7:0] r;

    initial begin
        do_reset();

        // ====================================================================
        $display("== [G1] MISC output + color/mono port aliasing ==");
        // After reset msr=0 -> MONO mode -> 0x3d0..0x3df invalid (read 0xff).
        io_peek(16'h3da, r);  chk("IS1 0x3da invalid in mono (read 0xff)", r, 8'hff);
        // Write MISC: msr = val & ~0x10. Write 0x67 (typical color mode) -> 0x67.
        io_out(16'h3c2, 8'h67);
        io_peek(16'h3cc, r);  chk("MISC read 0x3cc == msr (0x67)", r, 8'h67);
        // bit4 is masked off: write 0x10 -> stored 0x00 (well, 0x10 & ~0x10 = 0).
        io_out(16'h3c2, 8'h10);
        io_peek(16'h3cc, r);  chk("MISC masks bit4 (~0x10): 0x10 -> 0x00", r, 8'h00);
        // Now msr bit0 clear again -> mono. Re-enable color for the rest:
        io_out(16'h3c2, 8'h01);
        io_peek(16'h3cc, r);  chk("MISC color mode msr=0x01", r, 8'h01);
        // In color mode, 0x3b0..0x3bf invalid:
        io_peek(16'h3ba, r);  chk("IS1 mono 0x3ba invalid in color (0xff)", r, 8'hff);
        io_peek(16'h3da, r);  chk("IS1 color 0x3da valid in color (not 0xff)",
                                  (r == 8'hff) ? 8'h00 : 8'h01, 8'h01);
        // st00 read (0x3c2 read) stays 0 (not modeled as live):
        io_peek(16'h3c2, r);  chk("MISC read-port 0x3c2 == st00 (0x00)", r, 8'h00);

        // ====================================================================
        $display("== [G2] SEQUENCER index/data + sr_mask ==");
        io_out(16'h3c4, 8'h0f);                 // index = val & 7 -> 7
        io_peek(16'h3c4, r);  chk("SEQ index masked to &7 (0x0f->0x07)", r, 8'h07);
        io_out(16'h3c5, 8'hff);                 // sr[7] mask=0xff
        io_peek(16'h3c5, r);  chk("SEQ sr[7] full (mask 0xff)", r, 8'hff);
        io_out(16'h3c4, 8'h01);                 // index 1, mask 0x3d
        io_out(16'h3c5, 8'hff);
        io_peek(16'h3c5, r);  chk("SEQ sr[1] masked 0xff&0x3d=0x3d", r, 8'h3d);
        io_out(16'h3c4, 8'h00);                 // index 0, mask 0x03
        io_out(16'h3c5, 8'hff);
        io_peek(16'h3c5, r);  chk("SEQ sr[0] masked 0xff&0x03=0x03", r, 8'h03);

        // ====================================================================
        $display("== [G3] GRAPHICS index/data + gr_mask ==");
        io_out(16'h3ce, 8'hff);                 // index = val & 0x0f -> 0x0f
        io_peek(16'h3ce, r);  chk("GFX index masked &0x0f (0xff->0x0f)", r, 8'h0f);
        io_out(16'h3ce, 8'h05);                 // gr[5] mask 0x7b
        io_out(16'h3cf, 8'hff);
        io_peek(16'h3cf, r);  chk("GFX gr[5] masked 0xff&0x7b=0x7b", r, 8'h7b);
        io_out(16'h3ce, 8'h04);                 // gr[4] mask 0x03
        io_out(16'h3cf, 8'hff);
        io_peek(16'h3cf, r);  chk("GFX gr[4] masked 0xff&0x03=0x03", r, 8'h03);
        io_out(16'h3ce, 8'h08);                 // gr[8] mask 0xff
        io_out(16'h3cf, 8'hA5);
        io_peek(16'h3cf, r);  chk("GFX gr[8] full 0xA5", r, 8'hA5);

        // ====================================================================
        $display("== [G4] ATTRIBUTE flip-flop index/data ==");
        // Reset ff via IS1 read first (mono->ok? we are in color now -> 0x3da).
        io_in(16'h3da, r);                      // resets ar_flip_flop = 0
        // ff==0: write 0x3c0 sets ar_index = val & 0x3f.
        io_out(16'h3c0, 8'h05);                 // index <= 5, ff -> 1
        // ff==0 read of 0x3c0 returns ar_index. But ff is now 1, so read returns 0.
        io_peek(16'h3c0, r);  chk("ATTR 0x3c0 read==0 when ff=1 (data phase)", r, 8'h00);
        // ff==1: write 0x3c0 writes ar[5] (palette reg, mask 0x3f), ff->0.
        io_out(16'h3c0, 8'hff);                 // ar[5] <= 0xff & 0x3f = 0x3f
        // ff back to 0: read 0x3c0 returns ar_index (==5).
        io_peek(16'h3c0, r);  chk("ATTR 0x3c0 read==ar_index(5) when ff=0", r, 8'h05);
        // read 0x3c1 returns ar[ar_index&0x1f] = ar[5] = 0x3f.
        io_peek(16'h3c1, r);  chk("ATTR 0x3c1 read ar[5] (palette mask 0x3f)", r, 8'h3f);
        // ATC_MODE (idx 0x10) masks ~0x10:
        io_in(16'h3da, r);                      // reset ff -> index phase
        io_out(16'h3c0, 8'h10);                 // ar_index <= 0x10, ff -> 1 (data phase)
        io_out(16'h3c0, 8'hff);                 // ar[0x10] <= 0xff & ~0x10 = 0xef, ff -> 0
        // ff now 0 (index phase). Re-select idx 0x10 then read via 0x3c1.
        io_out(16'h3c0, 8'h10);                 // ar_index <= 0x10, ff -> 1
        // NOTE: do NOT issue a data write here -- that would overwrite ar[0x10].
        // 0x3c1 read returns ar[ar_index&0x1f] regardless of ff phase.
        io_peek(16'h3c1, r);  chk("ATTR ar[0x10] ATC_MODE masked ~0x10 (0xef)", r, 8'hef);

        // ATTR ff reset behaviour: with ff currently in data phase (==1), an IS1
        // read forces ff=0, so the NEXT 0x3c0 write is an INDEX write again.
        io_in(16'h3da, r);                      // IS1 read resets ff -> 0 (index phase)
        io_out(16'h3c0, 8'h0c);                 // ff==0 => INDEX write: ar_index <= 0x0c, ff->1
        io_in(16'h3da, r);                      // reset ff -> 0 so 0x3c0 read shows index
        io_peek(16'h3c0, r);  chk("ATTR IS1-read reset ff; index re-armed (0x0c)", r, 8'h0c);

        // ====================================================================
        $display("== [G5] CRTC index/data + CR11 lock ==");
        io_out(16'h3d4, 8'h0a);                 // cr_index = 0x0a (cursor start)
        io_peek(16'h3d4, r);  chk("CRTC index 0x3d4 readback (0x0a)", r, 8'h0a);
        io_out(16'h3d5, 8'h5a);
        io_peek(16'h3d5, r);  chk("CRTC cr[0x0a] writable (0x5a)", r, 8'h5a);
        // Set CR11 bit7 (lock CR0-7):
        io_out(16'h3d4, 8'h11);                 // index CR11
        io_out(16'h3d5, 8'h80);                 // CR11 = 0x80 (lock set)
        // Now try writing CR0 -> should be IGNORED.
        io_out(16'h3d4, 8'h00);                 // index CR0
        io_out(16'h3d5, 8'h33);                 // attempt write
        io_peek(16'h3d5, r);  chk("CRTC CR0 locked when CR11 bit7 (stays 0x00)", r, 8'h00);
        // CR7 (overflow): only bit4 writable when locked.
        io_out(16'h3d4, 8'h07);                 // index CR7
        io_out(16'h3d5, 8'hff);                 // only bit4 should stick
        io_peek(16'h3d5, r);  chk("CRTC CR7 locked: only bit4 writable (0x10)", r, 8'h10);
        // Clear CR11 lock and confirm CR0 writable again.
        io_out(16'h3d4, 8'h11);
        io_out(16'h3d5, 8'h00);                 // unlock
        io_out(16'h3d4, 8'h00);
        io_out(16'h3d5, 8'h33);
        io_peek(16'h3d5, r);  chk("CRTC CR0 writable after unlock (0x33)", r, 8'h33);
        // CRTC index is full 8 bits (not masked):
        io_out(16'h3d4, 8'hAB);
        io_peek(16'h3d4, r);  chk("CRTC index full 8 bits (0xAB)", r, 8'hAB);
        // Mono-alias 0x3b4/0x3b5 only valid in mono mode -- test below in G8.

        // ====================================================================
        $display("== [G6] DAC palette write + read auto-increment ==");
        // Write index 0x10, then write 3 triplets; sub_index wraps every 3.
        io_out(16'h3c8, 8'h10);                 // write index = 0x10, sub=0, state=0
        io_peek(16'h3c8, r);  chk("DAC write-index readback (0x10)", r, 8'h10);
        io_peek(16'h3c7, r);  chk("DAC dac_state after write-idx (0x00)", r, 8'h00);
        // triplet for palette entry 0x10: R=0x01 G=0x02 B=0x03
        io_out(16'h3c9, 8'h01);
        io_out(16'h3c9, 8'h02);
        io_out(16'h3c9, 8'h03);                 // 3rd write commits, write_index -> 0x11
        io_peek(16'h3c8, r);  chk("DAC write-index auto-inc after triplet (0x11)", r, 8'h11);
        // triplet for entry 0x11: R=0x04 G=0x05 B=0x06
        io_out(16'h3c9, 8'h04);
        io_out(16'h3c9, 8'h05);
        io_out(16'h3c9, 8'h06);
        io_peek(16'h3c8, r);  chk("DAC write-index auto-inc again (0x12)", r, 8'h12);

        // Now read back via read-index 0x10. dac_state -> 3 after setting read idx.
        io_out(16'h3c7, 8'h10);                 // read index = 0x10, sub=0, state=3
        io_peek(16'h3c7, r);  chk("DAC dac_state after read-idx (0x03)", r, 8'h03);
        io_in(16'h3c9, r);    chk("DAC read entry0x10 R (0x01)", r, 8'h01);
        io_in(16'h3c9, r);    chk("DAC read entry0x10 G (0x02)", r, 8'h02);
        io_in(16'h3c9, r);    chk("DAC read entry0x10 B (0x03)", r, 8'h03);
        // After 3 reads, read_index auto-incremented to 0x11.
        io_in(16'h3c9, r);    chk("DAC read entry0x11 R (0x04, auto-inc idx)", r, 8'h04);
        io_in(16'h3c9, r);    chk("DAC read entry0x11 G (0x05)", r, 8'h05);
        io_in(16'h3c9, r);    chk("DAC read entry0x11 B (0x06)", r, 8'h06);

        // ====================================================================
        $display("== [G7] INPUT STATUS 1 retrace toggle ==");
        // dumb retrace: read returns st01 ^ 0x09, and stores that into st01,
        // so consecutive reads alternate. We are in color mode -> 0x3da valid.
        io_in(16'h3da, r);
        chk("IS1 first read toggles bits 0x09 (0x09)", r & 8'h09, 8'h09);
        io_in(16'h3da, r);
        chk("IS1 second read toggles back (0x00)", r & 8'h09, 8'h00);
        io_in(16'h3da, r);
        chk("IS1 third read toggles again (0x09)", r & 8'h09, 8'h09);

        // ====================================================================
        $display("== [G8] color/mono CRTC alias (mono mode) ==");
        // Switch to mono mode (msr bit0 = 0). Use a value with bit0 clear.
        io_out(16'h3c2, 8'h66);                 // msr = 0x66 & ~0x10 = 0x66 (bit0=0)
        io_peek(16'h3cc, r);  chk("MISC mono mode msr=0x66", r, 8'h66);
        // In mono mode 0x3d0..0x3df invalid; 0x3b4/0x3b5 (mono CRTC) valid.
        io_peek(16'h3d4, r);  chk("CRTC color index 0x3d4 invalid in mono (0xff)", r, 8'hff);
        io_out(16'h3b4, 8'h0a);                 // mono CRTC index
        io_peek(16'h3b4, r);  chk("CRTC mono index 0x3b4 valid in mono (0x0a)", r, 8'h0a);
        io_out(16'h3b5, 8'h77);
        io_peek(16'h3b5, r);  chk("CRTC mono data 0x3b5 valid (0x77)", r, 8'h77);
        // IS1 mono alias 0x3ba toggles bits 0x09 between consecutive reads (the
        // absolute value depends on running st01 parity, so check the DELTA).
        begin
            logic [7:0] r1, r2;
            io_in(16'h3ba, r1);
            io_in(16'h3ba, r2);
            chk("IS1 mono 0x3ba valid: consecutive reads differ in 0x09",
                (r1 ^ r2) & 8'h09, 8'h09);
        end

        // ====================================================================
        $display("== [G9] synchronous reset clears state ==");
        do_reset();
        io_peek(16'h3cc, r);  chk("post-reset msr == 0", r, 8'h00);
        io_peek(16'h3c4, r);  chk("post-reset sr_index == 0", r, 8'h00);
        // msr=0 -> mono mode -> mono CRTC index valid:
        io_peek(16'h3b4, r);  chk("post-reset cr_index == 0 (via mono 0x3b4)", r, 8'h00);
        io_peek(16'h3c8, r);  chk("post-reset dac_write_index == 0", r, 8'h00);

        // ====================================================================
        $display("");
        if (errors == 0)
            $display("=== ven_vgaregs UNIT SELF-CHECK: PASS (%0d checks) ===", checks);
        else
            $display("=== ven_vgaregs UNIT SELF-CHECK: FAIL (%0d/%0d failed) ===", errors, checks);
        if (errors != 0) $fatal(1, "unit self-check failed");
        $finish;
    end

    // safety timeout
    initial begin
        #1_000_000;
        $display("=== TIMEOUT ===");
        $fatal(1, "timeout");
    end

endmodule
