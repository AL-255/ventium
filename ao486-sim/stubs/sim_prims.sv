// ao486-sim behavioral primitives + stubs.
//
// Replaces Altera megafunctions (altsyncram, altdpram) and the repo's dpram/
// dpram_difclk wrappers with plain behavioral SystemVerilog. These infer block
// RAM on both Verilator (sim) and Xilinx (Zynq US+ BRAM), so they double as the
// memory primitives for the eventual FPGA target. Also stubs cpu_export (sim
// debug) and uart (VHDL gh_uart_16550, off the boot path).
//
// Modeling notes match the instantiations in rtl/cache/{l1_icache,l2_cache}.v,
// rtl/soc/{ide,vga}.v, rtl/common/simple_fifo_mlab.v.

`ifndef AO486_SIM_PRIMS_SV
`define AO486_SIM_PRIMS_SV

// ---------------------------------------------------------------------------
// altsyncram — DUAL_PORT, mixed-width, byte-enabled write (port A) +
// registered-address / unregistered-output read (port B). 1-cycle read latency.
// Backing store is byte-granular so mixed widths (l2: 64b write / 32b read) work.
// ---------------------------------------------------------------------------
module altsyncram #(
    parameter address_aclr_b = "NONE",
    parameter address_reg_b = "CLOCK0",
    parameter byte_size = 8,
    parameter clock_enable_input_a = "BYPASS",
    parameter clock_enable_input_b = "BYPASS",
    parameter clock_enable_output_b = "BYPASS",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_type = "altsyncram",
    parameter numwords_a = 1,
    parameter numwords_b = 1,
    parameter operation_mode = "DUAL_PORT",
    parameter outdata_aclr_b = "NONE",
    parameter outdata_reg_b = "UNREGISTERED",
    parameter power_up_uninitialized = "FALSE",
    parameter read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter widthad_a = 1,
    parameter widthad_b = 1,
    parameter width_a = 1,
    parameter width_b = 1,
    parameter width_byteena_a = 1
)(
    input                        clock0,
    input                        clock1,
    input      [widthad_a-1:0]   address_a,
    input      [width_byteena_a-1:0] byteena_a,
    input      [width_a-1:0]      data_a,
    input                        wren_a,
    input      [widthad_b-1:0]   address_b,
    input                        byteena_b,
    input      [31:0]            data_b,
    input                        wren_b,
    output     [width_a-1:0]      q_a,
    output     [width_b-1:0]      q_b,
    input                        aclr0,
    input                        aclr1,
    input                        addressstall_a,
    input                        addressstall_b,
    input                        clocken0,
    input                        clocken1,
    input                        clocken2,
    input                        clocken3,
    output                       eccstatus,
    input                        rden_a,
    input                        rden_b
);
    localparam BYTES = (numwords_a * width_a) / 8;
    localparam BA    = width_a / 8;   // bytes per port-A word
    localparam BB    = width_b / 8;   // bytes per port-B word

    reg [7:0] mem [0:BYTES-1];

    // Port A: byte-enabled write (local loop var per block — must NOT share)
    always @(posedge clock0) begin
        for (int wk = 0; wk < BA; wk = wk + 1)
            if (wren_a && byteena_a[wk]) mem[address_a*BA + wk] <= data_a[wk*8 +: 8];
    end

    // Port B read: spec-literal address_reg_b=CLOCK0 (registered address) +
    // outdata_reg_b=UNREGISTERED (combinational output) -> q_b = mem[addr@last edge].
    reg [widthad_b-1:0] addr_b_r;
    always @(posedge clock0) addr_b_r <= address_b;
    reg [width_b-1:0] qb;
    always @(*) begin
        for (int rk = 0; rk < BB; rk = rk + 1) qb[rk*8 +: 8] = mem[addr_b_r*BB + rk];
    end
    assign q_b = qb;
    assign q_a = {width_a{1'b0}};
    assign eccstatus = 1'b0;
endmodule

// ---------------------------------------------------------------------------
// altdpram — MLAB simple dual-port: registered write (inclock), async read.
// ---------------------------------------------------------------------------
module altdpram #(
    parameter width = 1,
    parameter widthad = 1,
    parameter width_byteena = 1,
    parameter indata_aclr = "OFF",
    parameter indata_reg = "INCLOCK",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_type = "altdpram",
    parameter outdata_aclr = "OFF",
    parameter outdata_reg = "UNREGISTERED",
    parameter ram_block_type = "MLAB",
    parameter rdaddress_aclr = "OFF",
    parameter rdaddress_reg = "UNREGISTERED",
    parameter rdcontrol_aclr = "OFF",
    parameter rdcontrol_reg = "UNREGISTERED",
    parameter read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
    parameter wraddress_aclr = "OFF",
    parameter wraddress_reg = "INCLOCK",
    parameter wrcontrol_aclr = "OFF",
    parameter wrcontrol_reg = "INCLOCK"
)(
    input      [width-1:0]   data,
    input                    inclock,
    input                    outclock,
    input      [widthad-1:0] rdaddress,
    input      [widthad-1:0] wraddress,
    input                    wren,
    output     [width-1:0]   q,
    input                    aclr,
    input                    byteena,
    input                    inclocken,
    input                    outclocken,
    input                    rdaddressstall,
    input                    rden,
    input                    sclr,
    input                    wraddressstall
);
    reg [width-1:0] mem [0:(2**widthad)-1];
    always @(posedge inclock) if (wren) mem[wraddress] <= data;
    assign q = mem[rdaddress];
endmodule

// ---------------------------------------------------------------------------
// dpram — true dual-port, single clock, registered read (1-cycle). #(ADDR,DATA)
// ---------------------------------------------------------------------------
module dpram #(
    parameter ADDR = 8,
    parameter DATA = 8
)(
    input                  clock,
    input  [ADDR-1:0]      address_a,
    input  [DATA-1:0]      data_a,
    input                  wren_a,
    output reg [DATA-1:0]  q_a,
    input  [ADDR-1:0]      address_b,
    input  [DATA-1:0]      data_b,
    input                  wren_b,
    output reg [DATA-1:0]  q_b
);
    reg [DATA-1:0] mem [0:(2**ADDR)-1];
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule

// ---------------------------------------------------------------------------
// dpram_difclk — port A read/write on clk_a (registered read), port B read-only
// on clk_b with clock-enable. #(AW_A,DW_A,AW_B,DW_B); instances have A==B sizes.
// ---------------------------------------------------------------------------
module dpram_difclk #(
    parameter AW_A = 8,
    parameter DW_A = 8,
    parameter AW_B = 8,
    parameter DW_B = 8
)(
    input                  clk_a,
    input  [AW_A-1:0]      address_a,
    input  [DW_A-1:0]      data_a,
    input                  wren_a,
    output reg [DW_A-1:0]  q_a,
    input                  clk_b,
    input                  enable_b,
    input  [AW_B-1:0]      address_b,
    output reg [DW_B-1:0]  q_b
);
    reg [DW_A-1:0] mem [0:(2**AW_A)-1];
    always @(posedge clk_a) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clk_b) begin
        if (enable_b) q_b <= mem[address_b];
    end
endmodule

// ---------------------------------------------------------------------------
// cpu_export — sim/debug register export hook (no-op stub).
// ---------------------------------------------------------------------------
module cpu_export(
    input         clk,
    input         rst_n,
    input         new_export,
    input  [31:0] eax, ebx, ecx, edx, esp, ebp, esi, edi, eip
);
endmodule

`ifdef AO486_TRACE_EIP
// CS:EIP retire probe, bound into the ao486 `pipeline` module so it can see the
// internal cs/eip/exe_ready without editing the submodule RTL. Real-mode linear
// = (cs<<4)+eip; the C side disassembles / diffs from there.
module cpu_probe(
    input         clk,
    input         new_export,
    input  [15:0] cs,
    input  [31:0] eip,
    input  [31:0] esp,
    input  [31:0] eax,
    input  [63:0] cs_cache
);
    import "DPI-C" function void ao486_cpu_trace2(input int cs, input int eip,
                                                  input int esp, input int eax,
                                                  input int lin);
    import "DPI-C" function void ao486_dbg_cscache(input int lo, input int hi);
    // True code linear = CS descriptor base + eip, packed as { cs_cache[63:56],
    // cs_cache[39:16] } (see read_segment.v). Correct in real & protected mode,
    // unlike (cs<<4)+eip which is wrong for LDT/GDT selectors with a nonzero base.
    //
    // GATED behind AO486_TRUE_LIN. The cs_cache read here is a pure observer and was
    // verified execution-neutral (two builds, one reading cs_cache and one binding it
    // to 0, retire byte-for-byte identically). It is gated only as a conservative
    // default so the mainline build stays bit-identical to the original 4-input probe;
    // define AO486_TRUE_LIN for a disasm build that needs the true protected-mode
    // linear (LDT/GDT selectors with a nonzero base, where (cs<<4)+eip is wrong).
`ifdef AO486_TRUE_LIN
    wire [31:0] cs_base = { cs_cache[63:56], cs_cache[39:16] };
    always @(posedge clk) if (new_export) begin
        ao486_cpu_trace2({16'd0, cs}, eip, esp, eax, cs_base + eip);
        ao486_dbg_cscache(cs_cache[31:0], cs_cache[63:32]);
    end
`else
    always @(posedge clk) if (new_export)
        ao486_cpu_trace2({16'd0, cs}, eip, esp, eax, (cs << 4) + eip);
`endif
endmodule

`ifdef AO486_TRUE_LIN
bind pipeline cpu_probe cpu_probe_i(
    .clk(clk), .new_export(exe_ready), .cs(cs), .eip(exe_eip_final), .esp(esp), .eax(eax),
    .cs_cache(cs_cache)
);
`else
bind pipeline cpu_probe cpu_probe_i(
    .clk(clk), .new_export(exe_ready), .cs(cs), .eip(exe_eip_final), .esp(esp), .eax(eax),
    .cs_cache(64'd0)
);
`endif

// Co-simulated x87 FPU: forward each retiring ESC op (CMD_fpu=50 / CMDEX_ESC_STEP_0=1)
// to the C x87 model, and snapshot the paging state it needs to resolve the operand's
// linear address to physical. FNSTSW AX is a separate command (CMD_FNSTSW) handled in
// the execute datapath, so it does NOT fire this probe.
module fpu_probe(input clk, input fire, input escfire, input fpu_active, input [15:0] opmodrm, input [31:0] lin,
                 input [31:0] eipv, input [31:0] cr3v, input pg, input em, input ts);
    import "DPI-C" function void ao486_fpu_op(input int op_modrm, input int lin);
    import "DPI-C" function void ao486_paging(input int cr3, input int pg);
    import "DPI-C" function void ao486_emts(input int em, input int ts, input int esctrap);
    reg pem = 0, pts = 0;
    // `fire` (exe_ready && CMD_fpu && ESC_STEP_0) is HELD high while the ESC op sits in execute
    // across stall / mgmt cycles, so a level-triggered DPI call delivers the same op many times.
    // The C side used to de-dup by (opmodrm, lin) -- but that is indistinguishable from a tight
    // loop whose body is a single ESC instruction, e.g. Q_atof's
    //     0xe96e: fdiv st(1),st(0)   /  dec ecx / cmp ecx,esi / jg 0xe96e
    // whose iterations were silently swallowed (800.000000 parsed as 8000000.0). Deliver on the
    // RISING edge of `fire` instead (or when the op/operand changes while it stays high): that is
    // exactly once per retired ESC instruction, loop iterations included.
    //
    // BUT the rising edge alone DOUBLE-DELIVERS a memory-operand ESC op: FILD/FCOM/FADD m32 stall in
    // execute for the operand fetch, during which `fire` drops (exe_ready deasserts) and RE-RISES when
    // the operand is ready and the op re-enters ESC_STEP_0 -- all WITHIN THE SAME instruction (exe_cmd
    // stays CMD_fpu the whole time). Each spurious re-fire applies the op twice: an extra FILD push /
    // FSTP pop that leaks the x87 stack, eventually clobbering a live transform/view-origin register ->
    // Quake's camera flies out of bounds. Fix: a rising edge only counts as a NEW instruction if the
    // ESC op actually LEFT execute since the last delivery, i.e. some non-CMD_fpu op ran in between
    // (`armed`). A within-op stall keeps exe_cmd==CMD_fpu (fpu_active), so armed stays 0 and the
    // re-rise is ignored. Loop iterations (and consecutive different ESC ops) still deliver: the
    // dec/cmp/jg between iterations drop fpu_active (re-arm), and different ops fire on opmodrm/lin.
    //
    // BUT `armed` + (opmodrm/lin) is NOT enough for TWO CONSECUTIVE IDENTICAL register ESC ops with no
    // non-FPU op between them, e.g. the demo-interpolation epilogue
    //     0x2a64: fstp st(0)   /   0x2a66: fstp st(0)
    // Both are register ops: same opmodrm (dd/d8) AND same lin (register ops carry lin=cs_base, constant),
    // and fpu_active never drops between them, so armed stays 0 -> the SECOND fstp is swallowed. That
    // drops one x87 pop -> a stale const (+100 teleport bound) leaks up the stack, so the entity-origin
    // lerp reads its frac from ST(3)=100 instead of ~1 and the player origin overshoots ~100x -> Quake's
    // camera flies out of bounds at frame r_000034. Discriminate consecutive instructions by their eip:
    // it is CONSTANT across a within-op operand-fetch stall (so the double-fire fix above still holds) but
    // CHANGES between two distinct instructions (so both fstp deliver). This is the exact "one delivery
    // per retired ESC instruction" invariant we want.
    reg        pfire    = 1'b0;
    reg [15:0] popmodrm = 16'hffff;
    reg [31:0] plin     = 32'hffffffff;
    reg [31:0] peip     = 32'hffffffff;
    reg        armed    = 1'b1;
    always @(posedge clk) begin
        ao486_paging(cr3v, {31'd0, pg});
        if (fire && ((!pfire && armed) || opmodrm !== popmodrm || lin !== plin || eipv !== peip)) begin
            ao486_fpu_op({16'd0, opmodrm}, lin);
            armed <= 1'b0;                       // delivered this op; do not re-deliver on a within-op stall re-rise
        end
        if (!fpu_active) armed <= 1'b1;          // ESC op left execute (a non-FPU op ran) -> next rising edge is a real new op
        pfire    <= fire;
        popmodrm <= opmodrm;
        plin     <= lin;
        peip     <= eipv;
        // Log every CR0.EM / CR0.TS change: the co-sim ESC path fires only while EM=0 && TS=0;
        // the instant either is set, ESC ops trap (NM/INT7) and the co-sim goes silent. escfire
        // marks an ESC op that is being TRAPPED (em||ts set) -> the co-sim silently loses it.
        if (em !== pem || ts !== pts) ao486_emts({31'd0, em}, {31'd0, ts}, {31'd0, (escfire & (em | ts))});
        if (escfire & (em | ts)) ao486_emts({31'd0, em}, {31'd0, ts}, 32'd2);   // ESC op trapped
        pem <= em; pts <= ts;
    end
endmodule
bind pipeline fpu_probe fpu_probe_i(
    .clk(clk),
    .fire(exe_ready && exe_cmd == 7'd50 && exe_cmdex == 4'd1),   // co-sim FPU: process each ESC op (ao486 is 486SX, no HW FPU)
    .escfire(exe_cmd == 7'd50 && exe_cmdex == 4'd1),             // ESC op in execute (traps if EM||TS -> co-sim silent)
    .fpu_active(exe_cmd == 7'd50),                               // ANY step of an ESC op in execute: high across a within-op operand-fetch stall
    .opmodrm(exe_decoder[15:0]),
    .lin(exe_linear),
    .eipv(exe_eip_final),                                       // per-instruction eip: constant across a within-op stall, changes between two distinct consecutive ESC ops
    .cr3v(cr3),
    .pg(cr0_pg),
    .em(cr0_em),
    .ts(cr0_ts)
);

// debug: confirm DF-E0 decoded to CMD_FNSTSW (7'd118) and retired
module fnstsw_probe(input clk, input fire);
    import "DPI-C" function void ao486_fnstsw_dbg();
    always @(posedge clk) if (fire) ao486_fnstsw_dbg();
endmodule
bind pipeline fnstsw_probe fnstsw_probe_i(.clk(clk), .fire(exe_ready && exe_cmd == 7'd118));

// L1 icache output checker: every completed fetch, compare the data the icache
// returns to the known BIOS bytes in DDR -> pins the exact corrupted fetch.
module icache_probe(input clk, input done, input valid, input [31:0] addr,
                    input [31:0] data, input [31:0] rdaddr);
    import "DPI-C" function void ao486_icache_check(input int addr, input int data,
        input int valid, input int rdaddr);
    always @(posedge clk) if (done) ao486_icache_check(addr, data, {31'd0, valid}, rdaddr);
endmodule
bind l1_icache icache_probe icache_probe_i(
    .clk(CLK), .done(CPU_DONE), .valid(CPU_VALID), .addr(CPU_ADDR), .data(CPU_DATA),
    .rdaddr({read_addr, 2'b00})
);

// Detailed icache internals: data-RAM write + snoop inputs, to catch the
// corrupting write in a tight cycle window.
module icache_dprobe(input clk, input [31:0] memwe, input [31:0] memdatain,
                     input mreq, input [31:0] maddr, input mdone, input [31:0] mdata,
                     input [31:0] cpuaddr);
    import "DPI-C" function void ao486_icd(input int memwe, input int memdatain,
        input int mreq, input int maddr, input int mdone, input int mdata, input int cpuaddr);
    always @(posedge clk) ao486_icd(memwe, memdatain, {31'd0, mreq}, maddr,
        {31'd0, mdone}, mdata, cpuaddr);
endmodule
bind l1_icache icache_dprobe icache_dprobe_i(
    .clk(CLK), .memwe({28'd0, memory_we}), .memdatain(memory_datain),
    .mreq(MEM_REQ), .maddr(MEM_ADDR), .mdone(MEM_DONE), .mdata(MEM_DATA),
    .cpuaddr(CPU_ADDR)
);

// CPU-write snoop for FPU read-side coherency: forward every committed CPU->memory write
// (avalon_mem's snoop bus, asserted at write-commit — a few cycles before the write drains
// through the write-through L2 into ddr[]) to the co-sim, which overlays not-yet-drained
// stores onto FPU operand reads so a load never sees stale DDR bytes.
module snoop_probe(input clk, input we, input [27:2] addr, input [31:0] data, input [3:0] be);
    import "DPI-C" function void ao486_snoop_write(input int addr, input int data, input int be);
    always @(posedge clk) if (we) ao486_snoop_write({4'd0, addr, 2'b00}, data, {28'd0, be});
endmodule
bind avalon_mem snoop_probe snoop_probe_i(
    .clk(clk), .we(snoop_we), .addr(snoop_addr), .data(snoop_data), .be(snoop_be)
);

// I/O-write snoop: capture the Bochs debug console (port 0xE9) to read BIOS
// debug/panic messages directly, bypassing the VGA framebuffer.
module iowatch(input clk, input wdo, input [15:0] waddr, input [31:0] wdata);
    import "DPI-C" function void ao486_io_write(input int addr, input int data);
    reg pdo = 0;
    always @(posedge clk) begin
        if (wdo && !pdo) ao486_io_write({16'd0, waddr}, wdata);
        pdo <= wdo;
    end
endmodule
bind system iowatch iowatch_i(
    .clk(clk_sys), .wdo(cpu_io_write_do), .waddr(cpu_io_write_address), .wdata(cpu_io_write_data)
);

// I/O-READ snoop: catch a port read that never completes (CPU stalls on `in`).
module ioreadwatch(input clk, input rdo, input rdone, input [15:0] raddr);
    import "DPI-C" function void ao486_io_read(int addr, int done);
    always @(posedge clk) if (rdo) ao486_io_read({16'd0, raddr}, {31'd0, (rdo & ~rdone)});
endmodule
bind system ioreadwatch ioreadwatch_i(
    .clk(clk_sys), .rdo(cpu_io_read_do), .rdone(cpu_io_read_done), .raddr(cpu_io_read_address)
);

// RTC access snoop: port 0x70 write = register select, port 0x71 read = data value.
// Used to see exactly which RTC register a stuck boot loop polls and the value it waits for.
module rtcsnoop(input clk, input rdone, input [15:0] raddr, input [31:0] rdata,
                input wdo, input [15:0] waddr, input [31:0] wdata);
    import "DPI-C" function void ao486_rtc_acc(int rw, int val);
    reg pwdo = 0;
    always @(posedge clk) begin
        if (wdo && !pwdo && waddr == 16'h0070) ao486_rtc_acc(1, {24'd0, wdata[7:0]});
        if (rdone && raddr == 16'h0071)         ao486_rtc_acc(0, {24'd0, rdata[7:0]});
        pwdo <= wdo;
    end
endmodule
bind system rtcsnoop rtcsnoop_i(
    .clk(clk_sys), .rdone(cpu_io_read_done), .raddr(cpu_io_read_address), .rdata(cpu_io_read_data),
    .wdo(cpu_io_write_do), .waddr(cpu_io_write_address), .wdata(cpu_io_write_data)
);

// IDE wait/nodata/request snoop (bus_wait = ide0_wait|ide1_wait blocks ALL io).
module idewatch(input clk, input i0w, input i1w, input i0nd, input i1nd, input [2:0] i0r, input [2:0] i1r);
    import "DPI-C" function void ao486_ide_state(int i0w, int i1w, int i0nd, int i1nd, int i0r, int i1r);
    always @(posedge clk) ao486_ide_state({31'd0,i0w}, {31'd0,i1w}, {31'd0,i0nd}, {31'd0,i1nd}, {29'd0,i0r}, {29'd0,i1r});
endmodule
bind system idewatch idewatch_i(
    .clk(clk_sys), .i0w(ide0_wait), .i1w(ide1_wait), .i0nd(ide0_nodata), .i1nd(ide1_nodata),
    .i0r(ide0_request), .i1r(ide1_request)
);

// iobus snoop: why does a read not complete when bus_wait=0?
module iobuswatch(input clk, input rdo, input rdone, input wdo, input wdone, input brd, input bwr, input bwait, input [15:0] baddr);
    import "DPI-C" function void ao486_iobus(int rdo,int rdone,int wdo,int wdone,int brd,int bwr,int bwait,int baddr);
    always @(posedge clk) ao486_iobus({31'd0,rdo},{31'd0,rdone},{31'd0,wdo},{31'd0,wdone},{31'd0,brd},{31'd0,bwr},{31'd0,bwait},{16'd0,baddr});
endmodule

// VGA vertical-retrace probe: does host_io_vertical_retrace (0x3DA bit3) toggle?
module vgaretrace(input clk, input vretrace, input outvsync);
    import "DPI-C" function void ao486_vretrace(int vr, int ovs);
    always @(posedge clk) ao486_vretrace({31'd0,vretrace}, {31'd0,outvsync});
endmodule

// capture the data the CPU actually receives for 0x3DA reads
module rd3da(input clk, input rdone, input [15:0] raddr, input [31:0] rdata);
    import "DPI-C" function void ao486_rd3da(int addr, int data);
    always @(posedge clk) if (rdone && raddr==16'h03DA) ao486_rd3da({16'd0,raddr}, rdata);
endmodule
bind system rd3da rd3da_i(.clk(clk_sys), .rdone(cpu_io_read_done), .raddr(cpu_io_read_address), .rdata(cpu_io_read_data));


// IDE Device-Control (SRST) write probe + status-read tracking


// IDE/iobus wait-state probe (bind system - works)
module idewaitp(input clk, input i0w, input i1w, input i0nd, input [3:0] iadr, input ird, input i0cs, input [2:0] i0req);
    import "DPI-C" function void ao486_idewait(int i0w, int i1w, int i0nd, int iadr, int ird, int i0cs, int i0req);
    always @(posedge clk) ao486_idewait({31'd0,i0w},{31'd0,i1w},{31'd0,i0nd},{28'd0,iadr},{31'd0,ird},{31'd0,i0cs},{29'd0,i0req});
endmodule
bind system idewaitp idewaitp_i(.clk(clk_sys), .i0w(ide0_wait), .i1w(ide1_wait), .i0nd(ide0_nodata), .iadr(ide_address), .ird(iobus_read), .i0cs(ide0_cs), .i0req(ide0_request));


// interrupt delivery probe
module intrp(input clk, input ido, input idone, input i0, input i8, input i1);
    import "DPI-C" function void ao486_intr(int ido,int idone,int i0,int i8,int i1);
    always @(posedge clk) ao486_intr({31'd0,ido},{31'd0,idone},{31'd0,i0},{31'd0,i8},{31'd0,i1});
endmodule
bind system intrp intrp_i(.clk(clk_sys), .ido(interrupt_do), .idone(interrupt_done), .i0(irq_0), .i8(irq_8), .i1(irq_1));


// RTC config/interrupt probe (rtc is single instance)
module rtcp(input clk, input [2:0] divi, input [3:0] prate, input pena, input uena, input aena, input pint, input uint_, input irqv);
    import "DPI-C" function void ao486_rtc(int divi,int prate,int pena,int uena,int aena,int pint,int uint_,int irqv);
    always @(posedge clk) ao486_rtc({29'd0,divi},{28'd0,prate},{31'd0,pena},{31'd0,uena},{31'd0,aena},{31'd0,pint},{31'd0,uint_},{31'd0,irqv});
endmodule
bind rtc rtcp rtcp_i(.clk(clk), .divi(divider), .prate(periodic_rate), .pena(crb_int_periodic_ena), .uena(crb_int_update_ena), .aena(crb_int_alarm_ena), .pint(periodic_interrupt), .uint_(update_interrupt), .irqv(irq));

// RTC periodic-NCO probe: does ce_8192hz tick, does periodic_major count, does periodic_enabled hold?
module rtc_perprobe(input clk, input ce8192, input [12:0] pmajor, input pen, input pint);
    import "DPI-C" function void ao486_rtc_per(int ce8192, int pmajor, int pen, int pint);
    always @(posedge clk) ao486_rtc_per({31'd0,ce8192}, {19'd0,pmajor}, {31'd0,pen}, {31'd0,pint});
endmodule
bind rtc rtc_perprobe rtc_perprobe_i(.clk(clk), .ce8192(ce_8192hz), .pmajor(periodic_major), .pen(periodic_enabled), .pint(periodic_interrupt));


// CPU shutdown (triple-fault) probe
module cpu_shutdown_probe(input clk, input sd);
    import "DPI-C" function void ao486_shutdown(int s);
    always @(posedge clk) ao486_shutdown(sd ? 1 : 0);
endmodule
bind exception cpu_shutdown_probe cpu_shutdown_probe_i(.clk(clk), .sd(shutdown));

// Page-fault probe (co-sim wedge hunt): DISABLED for now. Binding a new observer into
// `ao486` can perturb Verilator's eval order for the UNOPTFLAT comb loops in the core and
// flip a timing-sensitive race, so keep the model execution-identical to the verified
// TRUE_LIN profile. Re-enable only if a DATA page fault's CR2 is specifically needed.
// module pf_probe(input clk, input rdpf, input wrpf, input [31:0] rcr2, input [31:0] wcr2,
//                 input [31:0] exeip, input [31:0] wreip, input [31:0] cr3v, input pg);
//     import "DPI-C" function void ao486_pagefault(int kind, int cr2, int exeip, int wreip, int cr3, int pg);
//     always @(posedge clk) begin
//         if (rdpf) ao486_pagefault(1, rcr2, exeip, wreip, cr3v, {31'd0, pg});
//         if (wrpf) ao486_pagefault(2, wcr2, exeip, wreip, cr3v, {31'd0, pg});
//     end
// endmodule
// bind ao486 pf_probe pf_probe_i(.clk(clk), .rdpf(read_page_fault), .wrpf(write_page_fault),
//     .rcr2(tlb_read_pf_cr2), .wcr2(tlb_write_pf_cr2), .exeip(exe_eip), .wreip(wr_eip),
//     .cr3v(cr3), .pg(cr0_pg));

// L2 cache state + VGA-write probe (capture text the BIOS prints to VGA memory)
module l2_probe(input clk, input [3:0] st, input vb, input cb, input [16:0] vaddr, input [7:0] vdout, input vwe);
    import "DPI-C" function void ao486_l2(int st, int vb, int cb, int vaddr, int vdout, int vwe);
    always @(posedge clk) ao486_l2({28'd0,st}, {31'd0,vb}, {31'd0,cb}, {15'd0,vaddr}, {24'd0,vdout}, {31'd0,vwe});
endmodule
bind l2_cache l2_probe l2_probe_i(.clk(CLK), .st(state), .vb(vgabusy), .cb(CPU_BUSY), .vaddr(VGA_ADDR), .vdout(VGA_DOUT), .vwe(VGA_WE));


// IDE-region io-write probe (bind system works)
module idewr(input clk, input iow, input [15:0] ioa, input [31:0] iod);
    import "DPI-C" function void ao486_idewrite(int addr, int data);
    always @(posedge clk) if (iow && ((ioa>=16'h01F0 && ioa<=16'h01F7) || ioa==16'h03F6)) ao486_idewrite({16'd0,ioa},iod);
endmodule

module iderd(input clk, input rdone, input [15:0] raddr, input [31:0] rdata);
    import "DPI-C" function void ao486_ideread(int addr, int data);
    always @(posedge clk) if (rdone && ((raddr>=16'h01F0 && raddr<=16'h01F7) || raddr==16'h03F6)) ao486_ideread({16'd0,raddr}, rdata);
endmodule
bind system iderd iderd_i(.clk(clk_sys), .rdone(cpu_io_read_done), .raddr(cpu_io_read_address[15:0]), .rdata(cpu_io_read_data));


// RTC io probe: index writes (0x70) + data reads (0x71)
module rtcio(input clk, input iow, input rdone, input [15:0] wa, input [15:0] ra, input [31:0] wd, input [31:0] rd);
    import "DPI-C" function void ao486_rtcio(int kind, int val);
    always @(posedge clk) begin
        if (iow && wa==16'h0070) ao486_rtcio(0, wd);      // index write
        if (rdone && ra==16'h0071) ao486_rtcio(1, rd);    // data read
    end
endmodule
bind system rtcio rtcio_i(.clk(clk_sys), .iow(iobus_write), .rdone(cpu_io_read_done), .wa(iobus_address[15:0]), .ra(cpu_io_read_address[15:0]), .wd(iobus_writedata), .rd(cpu_io_read_data));


// CPU memory-bus (avm/L2) stall probe
module memp(input clk, input rd, input wr, input wait_, input rdv, input [31:0] addr);
    import "DPI-C" function void ao486_mem(int rd,int wr,int wait_,int rdv,int addr);
    always @(posedge clk) ao486_mem({31'd0,rd},{31'd0,wr},{31'd0,wait_},{31'd0,rdv},addr);
endmodule
bind system memp memp_i(.clk(clk_sys), .rd(mem_read), .wr(mem_write), .wait_(mem_waitrequest), .rdv(mem_readdatavalid), .addr(mem_address));


// interrupt_possible probe (IF & pending) - bind ao486
module intposs(input clk, input ip, input ido, input idone);
    import "DPI-C" function void ao486_intposs(int ip, int ido, int idone);
    always @(posedge clk) ao486_intposs({31'd0,ip},{31'd0,ido},{31'd0,idone});
endmodule
bind ao486 intposs intposs_i(.clk(clk), .ip(wr_interrupt_possible), .ido(interrupt_do), .idone(interrupt_done));


// BIOS serial/debug console capture (0x3f8 UART THR, 0xe9, 0x402/0x403)
module bioscon(input clk, input iow, input [15:0] ioa, input [31:0] iod);
    import "DPI-C" function void ao486_bioscon(int addr, int ch);
    always @(posedge clk) if (iow && (ioa==16'h03f8 || ioa==16'h00e9 || ioa==16'h0402 || ioa==16'h0403 || ioa==16'h0401)) ao486_bioscon({16'd0,ioa}, {24'd0,iod[7:0]});
endmodule
bind system bioscon bioscon_i(.clk(clk_sys), .iow(iobus_write), .ioa(iobus_address[15:0]), .iod(iobus_writedata));

bind system idewr idewr_i(.clk(clk_sys), .iow(iobus_write), .ioa(iobus_address[15:0]), .iod(iobus_writedata));

bind vga vgaretrace vgaretrace_i(.clk(clk_sys), .vretrace(host_io_vertical_retrace), .outvsync(vga_vert_sync));

bind system iobuswatch iobuswatch_i(
    .clk(clk_sys), .rdo(cpu_io_read_do), .rdone(cpu_io_read_done), .wdo(cpu_io_write_do), .wdone(cpu_io_write_done),
    .brd(iobus_read), .bwr(iobus_write), .bwait(ide0_wait|ide1_wait), .baddr(iobus_address)
);



`endif

// ---------------------------------------------------------------------------
// uart — stub for rtl/soc/uart/uart.v (VHDL gh_uart_16550 is off the boot path).
// Outputs idle; no COM port. SV-rewrite later if a serial port is needed.
// ---------------------------------------------------------------------------
module uart(
    input            clk,
    input            reset,
    input      [2:0] address,
    input            write,
    input      [7:0] writedata,
    input            read,
    output     [7:0] readdata,
    input            cs,
    input            br_clk,
    input            rx,
    output           tx,
    input            cts_n,
    input            dcd_n,
    input            dsr_n,
    input            ri_n,
    output           rts_n,
    output           br_out,
    output           dtr_n,
    output           irq
);
    assign readdata = 8'h00;
    assign tx     = 1'b1;   // idle mark
    assign rts_n  = 1'b1;   // deasserted (active-low)
    assign br_out = 1'b0;
    assign dtr_n  = 1'b1;   // deasserted (active-low)
    assign irq    = 1'b0;
endmodule

`endif

// ---------------------------------------------------------------------------
// mpu — MPU-401 MIDI UART stub (off the boot path).
// ---------------------------------------------------------------------------
module mpu(
    input            clk,
    input            br_clk,
    input            reset,
    input            address,
    input      [7:0] writedata,
    input            read,
    input            write,
    output     [7:0] readdata,
    input            cs,
    input            rx,
    output           tx,
    input            double_rate,
    output           irq
);
    assign readdata = 8'h00;
    assign tx  = 1'b1;
    assign irq = 1'b0;
endmodule
