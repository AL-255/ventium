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
    input  [31:0] eax
);
    import "DPI-C" function void ao486_cpu_trace2(input int cs, input int eip,
                                                  input int esp, input int eax);
    always @(posedge clk) if (new_export) ao486_cpu_trace2({16'd0, cs}, eip, esp, eax);
endmodule

bind pipeline cpu_probe cpu_probe_i(
    .clk(clk), .new_export(exe_ready), .cs(cs), .eip(exe_eip_final), .esp(esp), .eax(eax)
);

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
    always @(posedge clk) if (rdo|wdo) ao486_iobus({31'd0,rdo},{31'd0,rdone},{31'd0,wdo},{31'd0,wdone},{31'd0,brd},{31'd0,bwr},{31'd0,bwait},{16'd0,baddr});
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


// CPU shutdown (triple-fault) probe


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
