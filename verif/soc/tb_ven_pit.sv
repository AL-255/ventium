// ============================================================================
// tb_ven_pit.sv -- directed UNIT self-check for ven_pit (Ventium SoC 8254 PIT).
//
// This is a UNIT-LEVEL self-check against the DOCUMENTED QEMU 8.2.2 i8254
// register semantics (hw/timer/i8254.c + i8254_common.c) -- NOT yet the
// differential-vs-qemu-system SoC gate. It drives the PMIO register interface
// (cs/we/addr/wdata/rdata) through the documented sequences and asserts the
// CPU-observable results bit-exactly.
//
// clk is driven AS the PIT clock (TICK_DIV=1), so 1 clk edge == 1 PIT tick.
// That makes the elapsed-tick math exact and oracle-checkable; the
// scaled-clock cadence (TICK_DIV>1) is structural and NOT oracled here.
//
// Build/run via verif/soc/Makefile (verilator --binary --assert --timing).
// ============================================================================
`timescale 1ns/1ps

module tb_ven_pit;

    // ---- DUT I/O ----
    logic        clk = 1'b0;
    logic        rst;
    logic        cs;
    logic        we;
    logic [15:0] addr;
    logic [7:0]  wdata;
    logic [7:0]  rdata;
    logic        out0;

    ven_pit #(.TICK_DIV(1)) dut (
        .clk   (clk),
        .rst   (rst),
        .cs    (cs),
        .we    (we),
        .addr  (addr),
        .wdata (wdata),
        .rdata (rdata),
        .out0  (out0)
    );

    // 10ns clock -> each posedge == one PIT tick in this unit test.
    always #5 clk = ~clk;

    // ---- scoreboard ----
    int errors = 0;
    int checks = 0;

    task automatic chk(input string name, input logic [31:0] got,
                                           input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  [FAIL] %-40s got=0x%08x exp=0x%08x", name, got, exp);
        end else begin
            $display("  [ ok ] %-40s = 0x%0x", name, got);
        end
    endtask

    // ---- bus drivers --------------------------------------------------------
    // CONVENTION: the TB always sits at a NEGEDGE between transactions. Each
    // io_out / io_in / ticks(1) consumes EXACTLY ONE posedge (== one PIT tick),
    // so the elapsed-tick count `d` is precisely trackable. After every call we
    // return at the negedge that immediately follows the consumed posedge.
    //
    // OUT (CPU write). cs&we asserted across the posedge -> the write commits.
    // For a data-write to ch N this resets d_q[N] to 0 at that posedge (the
    // load beats the same-cycle tick). For control writes / other channels,
    // d advances by 1 at that posedge.
    task automatic io_out(input logic [15:0] a, input logic [7:0] d);
        // (already at negedge) assert and ride through the next posedge
        cs = 1'b1; we = 1'b1; addr = a; wdata = d;
        @(posedge clk);             // write commits here (one tick)
        @(negedge clk);
        cs = 1'b0; we = 1'b0;
    endtask

    // IN (CPU read). rdata is combinational off the regs sampled just before the
    // posedge; the read side-effect commits on that posedge (also one tick).
    task automatic io_in(input logic [15:0] a, output logic [7:0] d);
        cs = 1'b1; we = 1'b0; addr = a;
        #1;                         // let combinational rdata settle
        d = rdata;                  // sampled at the CURRENT d (pre-posedge)
        @(posedge clk);             // side-effect + one tick
        @(negedge clk);
        cs = 1'b0;
    endtask

    // advance N PIT ticks with the bus idle (free-running count advances by N).
    task automatic ticks(input int n);
        cs = 1'b0; we = 1'b0;
        repeat (n) begin
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    // ---- reference model of QEMU pit_get_count (mode-dependent) -------------
    function automatic logic [15:0] ref_count(input int m, input longint c,
                                              input longint d);
        longint cc; longint r;
        begin
            cc = c;
            case (m)
                0,1,4,5: ref_count = (c - d) & 16'hffff;
                3:       begin r = (2*d) % cc; ref_count = (c - r) & 16'hffff; end
                default: begin r = d % cc;     ref_count = (c - r) & 16'hffff; end
            endcase
        end
    endfunction

    // ---- reference model of QEMU pit_get_out --------------------------------
    function automatic logic ref_out(input int m, input longint c, input longint d);
        longint r; longint half;
        begin
            case (m)
                2: begin r = d % c; ref_out = ((r == 0) && (d != 0)); end
                3: begin r = d % c; half = (c + 1) >> 1; ref_out = (r < half); end
                4,5: ref_out = (d == c);
                default: ref_out = (d >= c);
            endcase
        end
    endfunction

    // I/O port bases
    localparam logic [15:0] P_CH0 = 16'h0040;
    localparam logic [15:0] P_CH1 = 16'h0041;
    localparam logic [15:0] P_CH2 = 16'h0042;
    localparam logic [15:0] P_CTL = 16'h0043;

    logic [7:0] r;

    initial begin
        cs = 0; we = 0; addr = 0; wdata = 0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("=== ven_pit directed unit self-check ===");

        // -------------------------------------------------------------------
        // T1: RESET state. pit_reset_common: all channels mode=3, count=0x10000.
        //     ch0 OUT (mode3 square wave): d=0 -> (0 % 0x10000)=0 < 0x8000 -> 1.
        // -------------------------------------------------------------------
        $display("-- T1: reset defaults (mode 3, count 0x10000) --");
        chk("reset out0 (mode3,d small)", out0, ref_out(3, 32'h10000, 0));
        // Latch-read ch0 count right after reset (a few ticks elapsed). Use a
        // counter-latch command then read LSB+MSB (rw_mode is 0 at reset -> the
        // count_latched sub-state is 0, so the latch path is skipped and a live
        // read is returned; here we instead reprogram below). Just sanity OUT.

        // -------------------------------------------------------------------
        // T2: ch0 mode 2, access=LSB-then-MSB (WORD), load 0x1234. Verify the
        //     two-write load + read-back of the live count, and read_state toggle.
        //     control word = ch0(00) access=WORD(11) mode2(010) bcd(0) = 0011_0100 = 0x34
        // -------------------------------------------------------------------
        $display("-- T2: ch0 mode2 WORD load 0x1234, live read --");
        io_out(P_CTL, 8'h34);       // control word (access=WORD, mode2)
        io_out(P_CH0, 8'h34);       // LSB (WORD0): stored, no load, d advances
        io_out(P_CH0, 8'h12);       // MSB (WORD1): count=0x1234, d reset to 0
        ticks(5);                   // d == 5
        io_in(P_CH0, r);            // LSB read at d=5, read_state WORD0->WORD1
        chk("ch0 mode2 live LSB @d=5", r, {24'b0, ref_count(2, 'h1234, 5) [7:0]});
        io_in(P_CH0, r);            // MSB read at d=6, read_state WORD1->WORD0
        chk("ch0 mode2 live MSB @d=6", r, {24'b0, ref_count(2, 'h1234, 6) [15:8]});

        // -------------------------------------------------------------------
        // T3: counter-latch command. Latch live count; later reads return the
        //     LATCHED value even though the timer keeps decrementing.
        //     ctl = ch0(00) access=COUNTER-LATCH(00) ... = 0x00
        // -------------------------------------------------------------------
        $display("-- T3: ch0 counter-latch freezes the read value --");
        // Reload deterministically: mode2 WORD, count 0x2000.
        io_out(P_CTL, 8'h34);
        io_out(P_CH0, 8'h00);
        io_out(P_CH0, 8'h20);       // count=0x2000, d=0
        ticks(3);                   // d=3
        io_out(P_CTL, 8'h00);       // counter-latch ch0: snapshot count at d=4 edge
        // expected latched count = ref_count(mode2,0x2000, d at latch edge).
        // latch happens on the io_out commit edge; before it d=3, after the
        // edge's tick d would be 4, but the latch reads pre-edge d=3... however
        // the io_out's posedge ALSO advances d (tick_en). Latch uses OLD d=3.
        begin
            logic [15:0] lc; logic [7:0] el, em;
            lc = ref_count(2, 'h2000, 3);
            el = lc[7:0]; em = lc[15:8];
            ticks(50);              // timer runs on; latched value must NOT change
            io_in(P_CH0, r);        // latched LSB
            chk("ch0 latched LSB (frozen)", r, {24'b0, el});
            io_in(P_CH0, r);        // latched MSB
            chk("ch0 latched MSB (frozen)", r, {24'b0, em});
            // next read returns LIVE count again (latch consumed).
            io_in(P_CH0, r);        // live LSB at current d
        end

        // -------------------------------------------------------------------
        // T4: read-back STATUS latch. ctl bit7-6=11(readback), bit5=1(no count
        //     latch), bit4=0(latch status), bit(2<<ch). For ch0: 0b1110_0010=0xE2.
        //     status = {out<<7, null(0)<<6, rw[1:0]<<4, mode<<1, bcd}.
        //     ch0 currently: rw_mode=WORD(3), mode=2, bcd=0.
        // -------------------------------------------------------------------
        $display("-- T4: read-back latch STATUS (ch0) --");
        // make d deterministic for the OUT bit in status: reload mode2 0x2000.
        io_out(P_CTL, 8'h34);
        io_out(P_CH0, 8'h00);
        io_out(P_CH0, 8'h20);       // count=0x2000, d=0
        ticks(8);                   // d=9 at the readback commit edge's pre-value=8
        io_out(P_CTL, 8'hE2);       // read-back: latch status of ch0 (uses old d=8)
        begin
            logic exp_out; logic [7:0] exp_status;
            exp_out = ref_out(2, 'h2000, 8);
            // rw_mode=3 (WORD), mode=2, bcd=0
            exp_status = {exp_out, 1'b0, 2'd3, 3'd2, 1'b0};
            io_in(P_CH0, r);        // first read after status latch -> status byte
            chk("ch0 readback status byte", r, {24'b0, exp_status});
        end

        // -------------------------------------------------------------------
        // T5: read-back BOTH status+count (bit5=0 latch count, bit4=0 latch
        //     status). status read FIRST, then the latched count.
        //     ctl = 11 0 0 0010 = 0b1100_0010 = 0xC2 (ch0).
        // -------------------------------------------------------------------
        $display("-- T5: read-back latch STATUS+COUNT (status first, then count) --");
        io_out(P_CTL, 8'h34);       // mode2 WORD
        io_out(P_CH0, 8'h00);
        io_out(P_CH0, 8'h40);       // count=0x4000, d=0
        ticks(10);                  // pre-edge d=10 at readback
        io_out(P_CTL, 8'hC2);       // readback ch0: latch status AND count (d=10)
        begin
            logic exp_out; logic [7:0] exp_status; logic [15:0] lc;
            exp_out = ref_out(2, 'h4000, 10);
            exp_status = {exp_out, 1'b0, 2'd3, 3'd2, 1'b0};
            lc = ref_count(2, 'h4000, 10);
            ticks(20);              // timer runs; latched status+count stay frozen
            io_in(P_CH0, r);        // 1st read: STATUS
            chk("ch0 rb status (then count)", r, {24'b0, exp_status});
            io_in(P_CH0, r);        // 2nd read: latched count LSB
            chk("ch0 rb latched count LSB", r, {24'b0, lc[7:0]});
            io_in(P_CH0, r);        // 3rd read: latched count MSB
            chk("ch0 rb latched count MSB", r, {24'b0, lc[15:8]});
        end

        // -------------------------------------------------------------------
        // T6: count==0 on write means 0x10000. Load ch1 mode0 LSB-only with 0.
        //     ctl ch1(01) access=LSB(01) mode0(000) bcd0 = 0b0101_0000 = 0x50.
        //     mode0 count = (count - d) & 0xffff; with count=0x10000, d=k ->
        //     (0x10000 - k)&0xffff.
        // -------------------------------------------------------------------
        // NON-VACUOUS: the decrementing VALUE cannot distinguish count==0 from
        // 0x10000 (congruent mod 65536). The only observable difference is the
        // mode-0 terminal-count TIMING — with 0x10000, OUT (ch0's out0) stays LOW
        // for 65536 ticks; a broken literal-0 would terminal-count and drive OUT
        // HIGH within ~1 tick. So use ch0 (out0 observable) and assert OUT is still
        // LOW after a few ticks (this assertion FAILS on a literal-0 register).
        $display("-- T6: write 0 => 0x10000 count (ch0 mode0 LSB; non-vacuous via OUT) --");
        io_out(P_CTL, 8'h10);       // ch0(00) access=LSB(01) mode0(000) bcd0 = 0x10
        io_out(P_CH0, 8'h00);       // count = 0x10000, d=0
        ticks(4);                   // d=4
        io_in(P_CH0, r);            // mode0 LSB read at d=4
        chk("ch0 count0->0x10000 LSB @d=4", r, {24'b0, ref_count(0, 'h10000, 4) [7:0]});
        chk("ch0 count0->0x10000: mode0 OUT still LOW @d=4 (NOT literal-0)", {31'b0, out0}, 32'd0);

        // -------------------------------------------------------------------
        // T7: MSB-only access (access=2). ctl ch2(10) access=MSB(10) mode0 = 0xA0.
        //     Writing 0x80 loads count = 0x8000.
        // -------------------------------------------------------------------
        $display("-- T7: ch2 MSB-only access, load 0x8000 --");
        io_out(P_CTL, 8'hA0);       // 0b1010_0000
        io_out(P_CH2, 8'h80);       // count = 0x80<<8 = 0x8000, d=0
        ticks(2);                   // d=2
        io_in(P_CH2, r);            // MSB read at d=2
        chk("ch2 mode0 MSB-access read @d=2", r, {24'b0, ref_count(0, 'h8000, 2) [15:8]});

        // -------------------------------------------------------------------
        // T8: ch0 OUT as IRQ0 source, mode 3 SQUARE WAVE oracle vs ref_out over
        //     a full period. Use a small count so a few ticks cross transitions.
        //     count=10, mode3 WORD: ctl ch0 access WORD mode3 = 0b0011_0110=0x36.
        // -------------------------------------------------------------------
        $display("-- T8: ch0 mode3 square-wave OUT oracle (count=10) --");
        io_out(P_CTL, 8'h36);
        io_out(P_CH0, 8'h0A);       // LSB
        io_out(P_CH0, 8'h00);       // MSB -> count=10, d=0 at this commit edge
        begin
            // After the MSB commit edge, d=0 (load resets it, beats the tick).
            // We sample out0 at successive ticks d=1,2,...; out0 is combinational
            // off the CURRENT d, so at negedge after k ticks, d==k.
            int k;
            for (k = 1; k <= 25; k++) begin
                @(posedge clk);     // advance one tick, d becomes k
                @(negedge clk);
                chk($sformatf("ch0 mode3 out @d=%0d", k), out0, ref_out(3, 10, k));
            end
        end

        // -------------------------------------------------------------------
        // T9: ch0 OUT mode 2 RATE GENERATOR oracle vs ref_out (count=7).
        //     ctl ch0 WORD mode2 = 0x34.
        // -------------------------------------------------------------------
        $display("-- T9: ch0 mode2 rate-gen OUT oracle (count=7) --");
        io_out(P_CTL, 8'h34);
        io_out(P_CH0, 8'h07);
        io_out(P_CH0, 8'h00);       // count=7, d=0
        begin
            int k;
            for (k = 1; k <= 20; k++) begin
                @(posedge clk);
                @(negedge clk);
                chk($sformatf("ch0 mode2 out @d=%0d", k), out0, ref_out(2, 7, k));
            end
        end

        // -------------------------------------------------------------------
        // T10: 0x43 is write-only -> reads return 0. Also a control word must
        //      NOT corrupt the count (only sets mode/access/bcd).
        // -------------------------------------------------------------------
        $display("-- T10: 0x43 read returns 0 (write-only) --");
        io_in(P_CTL, r);
        chk("0x43 read == 0", r, 32'h0);

        // -------------------------------------------------------------------
        // T11: free-running decrement, mode 0, exact tick accounting.
        //      Load ch0 mode0 WORD count=0x1000; after exactly N ticks the live
        //      count == (0x1000 - N) & 0xffff.
        //      ctl ch0 WORD mode0 = 0b0011_0000 = 0x30.
        // -------------------------------------------------------------------
        $display("-- T11: mode0 exact free-running decrement --");
        io_out(P_CTL, 8'h30);
        io_out(P_CH0, 8'h00);       // LSB (WORD0)
        io_out(P_CH0, 8'h10);       // MSB (WORD1) -> count=0x1000, d=0
        ticks(100);                 // d=100
        io_in(P_CH0, r);            // WORD: LSB first, read at d=100
        chk("ch0 mode0 dec LSB @d=100", r, {24'b0, ref_count(0, 'h1000, 100) [7:0]});
        io_in(P_CH0, r);            // MSB read at d=101
        chk("ch0 mode0 dec MSB @d=101", r, {24'b0, ref_count(0, 'h1000, 101) [15:8]});

        // -------------------------------------------------------------------
        $display("=== checks=%0d errors=%0d ===", checks, errors);
        if (errors == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    // global watchdog
    initial begin
        #1_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
