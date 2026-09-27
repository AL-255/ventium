`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// ven_ao486_shim.sv — drop-in replacement for the ao486 core inside system.v.
//
// Presents the EXACT ao486 port list (ao486.v:29-76) so system.v needs only a
// module-name swap at its one CPU instantiation. Internally wraps ventium_top
// (built +VEN_L1_AXI +VEN_KV260_SOC +VEN_TRANSCENDENTAL) + the AXI4→Avalon bridge
// and the io / interrupt / A20 adapters. See VENTIUM_SWAP.md.
//
// Memory: ventium_top.m_axi_* (identity phys under the KV260 REMAP_BASE offset,
// which the shim removes) → A20 gate → ven_axi2avalon → avm_* → l2_cache.
// I/O:   ventium_top.io_*  → split io_read_*/io_write_*.
// INTR:  interrupt_do/vector → ventium intr/inta_vector; ventium inta → interrupt_done.
// DMA:   tied off (IDE boot is PIO; no ISA DMA touches the CPU cache).

module ven_ao486_shim
(
    input               clk,
    input               rst_n,

    input               a20_enable,
    input               cache_disable,   // (ignored — gated ao486's L1 only)

    // interrupt (8259 PIC ↔ CPU)
    input               interrupt_do,
    input   [7:0]       interrupt_vector,
    output              interrupt_done,

    // memory bus (Avalon-MM burst)
    output      [29:0]  avm_address,
    output      [31:0]  avm_writedata,
    output      [3:0]   avm_byteenable,
    output      [3:0]   avm_burstcount,
    output              avm_write,
    output              avm_read,
    input               avm_waitrequest,
    input               avm_readdatavalid,
    input       [31:0]  avm_readdata,

    // dma bus (slave) — tied off
    input       [23:0]  dma_address,
    input               dma_16bit,
    input               dma_write,
    input       [15:0]  dma_writedata,
    input               dma_read,
    output      [15:0]  dma_readdata,
    output              dma_readdatavalid,
    output              dma_waitrequest,

    // io bus (split read/write)
    output              io_read_do,
    output       [15:0] io_read_address,
    output       [2:0]  io_read_length,
    input        [31:0] io_read_data,
    input               io_read_done,
    output              io_write_do,
    output       [15:0] io_write_address,
    output       [2:0]  io_write_length,
    output       [31:0] io_write_data,
    input               io_write_done,

    // ---- on-die debug bundle (VEN_DBG_CORE): packed to keep the ao486 `system` boundary small.
    // dbg_bus (up):   [0]inta [1]retire_valid [33:2]eip [49:34]cs [81:50]esp [113:82]eflags
    //                 [119:114]state [127:120]int_vec [159:128]fault_pc [191:160]cr0 [192]rd_valid
    //                 [224:193]rd_addr [256:225]rd_data [257]cmp_freeze [258]halted
    //                 [290:259]selected architectural-state word
    // dbg_cmp (down): [31:0]cmp_cfg [63:32]cmp_range [64]halt_req [65]step [66]bp_en
    //                 [98:67]bp_addr [99]bp_clr [106:100]arch_sel
    output      [290:0] dbg_bus,
    input       [127:0] dbg_cmp
);

    // KV260 build offsets the AXI address by REMAP_BASE and folds to 256 MiB
    // (ventium_top.sv:926/934). The MemModel/l2 want the raw x86 phys, so undo it.
    localparam logic [39:0] REMAP_BASE = 40'h0_4000_0000;

    // ---------------------------------------------------------------- DMA: idle
    assign dma_readdata      = 16'h0;
    assign dma_readdatavalid = 1'b0;
    assign dma_waitrequest   = 1'b0;   // not on the boot path; revisit for SB16/FDC DMA

    // ------------------------------------------------------- Ventium ↔ adapter nets
    // io_* (unified, from the core)
    logic        v_io_req, v_io_we;
    logic [15:0] v_io_addr;
    logic [2:0]  v_io_size;
    logic [31:0] v_io_wdata, v_io_rdata;
    logic        v_io_ack;
    // interrupt
    logic        v_inta;
    // AXI master (from the core)
    logic [3:0]  m_awid;   logic [39:0] m_awaddr; logic [7:0] m_awlen; logic [2:0] m_awsize;
    logic [1:0]  m_awburst; logic m_awlock; logic [3:0] m_awcache; logic [2:0] m_awprot;
    logic [3:0]  m_awqos;  logic m_awvalid, m_awready;
    logic [31:0] m_wdata;  logic [3:0] m_wstrb; logic m_wlast, m_wvalid, m_wready;
    logic [3:0]  m_bid;    logic [1:0] m_bresp; logic m_bvalid, m_bready;
    logic [3:0]  m_arid;   logic [39:0] m_araddr; logic [7:0] m_arlen; logic [2:0] m_arsize;
    logic [1:0]  m_arburst; logic m_arlock; logic [3:0] m_arcache; logic [2:0] m_arprot;
    logic [3:0]  m_arqos;  logic m_arvalid, m_arready;
    logic [3:0]  m_rid;    logic [31:0] m_rdata; logic [1:0] m_rresp; logic m_rlast, m_rvalid, m_rready;
    logic        v_bus_err, v_m_idle, v_cpu_hung;
    logic [63:0] v_retire_count;

    // -------------------------------------------------------- A20 + REMAP undo
    function automatic logic [39:0] a20_remap(input logic [39:0] axi_addr);
        logic [39:0] phys = axi_addr - REMAP_BASE;                 // undo KV260 offset
        return a20_enable ? phys : (phys & ~40'h0000_0010_0000);   // A20 mask bit 20
    endfunction

    // -------------------------------------------------------- I/O split adapter
    // The ao486 iobus FSM (soc/iobus.v) re-triggers a NEW bus transaction every time it
    // returns to S_IDLE with cpu_read_do/cpu_write_do still asserted. Ventium HOLDS v_io_req
    // until it observes io_ack and deasserts a cycle later, so a single Ventium io read would
    // spawn MULTIPLE iobus reads — and each extra read pulses the device read strobe (e.g.
    // clearing the VGA sticky-retrace bit / advancing a read-sensitive port), so the value
    // Ventium finally captures is the LAST, wrong one. Gate the strobes so exactly ONE iobus
    // transaction happens per v_io_req assertion: suppress once done, re-arm when v_io_req drops.
    logic io_done_seen;
    always_ff @(posedge clk) begin
        if (!rst_n)                            io_done_seen <= 1'b0;
        else if (!v_io_req)                    io_done_seen <= 1'b0;   // request released → arm next
        else if (io_read_done | io_write_done) io_done_seen <= 1'b1;   // this txn completed
    end

    // NOTE: io_done_seen alone has a 1-CYCLE RACE — it is registered, so it only suppresses
    // io_read_do the cycle AFTER io_read_done. But the iobus returns to S_IDLE that very cycle
    // and, seeing cpu_read_do still high, RE-TRIGGERS a spurious 2nd read. On a read-sensitive
    // port (the IDE data FIFO) that 2nd read advances io_cnt, so the identify/sector transfer
    // double-steps and drq clears early -> the core reads zeros. Also gate on io_*_done
    // COMBINATIONALLY so io_read_do drops the instant the transaction completes (no 2nd read).
    assign io_read_do      = v_io_req & ~v_io_we & ~io_done_seen & ~(io_read_done | io_write_done);
    assign io_write_do     = v_io_req &  v_io_we & ~io_done_seen & ~(io_read_done | io_write_done);
    assign io_read_address = v_io_addr;
    assign io_write_address= v_io_addr;
    assign io_read_length  = v_io_size;    // both encode byte-count 1/2/4
    assign io_write_length = v_io_size;
    assign io_write_data   = v_io_wdata;
    assign v_io_ack        = io_read_done | io_write_done;
    assign v_io_rdata      = io_read_data;

`ifdef VEN_DBG_CORE
    // [IOSTUCK] — a HELD-unacked port-I/O request. Ventium keeps v_io_req asserted until it
    // sees v_io_ack (S_IO waits), so if the ao486 iobus never completes this port (io_*_done
    // never fires) the core stalls FOREVER: retires freeze, and — because port I/O bypasses the
    // dcache — ven_l1d stays quiet ([L1DSTUCK] won't fire). This is the Quake-hang signature.
    // Fire ONCE, dumping the offending port + full handshake state.
    integer io_stk_cnt; logic io_stk_fired;
    always_ff @(posedge clk) begin
        if (!rst_n) begin io_stk_cnt <= 0; io_stk_fired <= 1'b0; end
        else if (v_io_req & ~v_io_ack) begin
            io_stk_cnt <= io_stk_cnt + 1;
            if (io_stk_cnt == 200000 && !io_stk_fired) begin
                io_stk_fired <= 1'b1;
                $display("[IOSTUCK] port=%04x we=%0d size=%0d wdata=%08x done_seen=%0d rd_do=%0d wr_do=%0d rd_done=%0d wr_done=%0d",
                         v_io_addr, v_io_we, v_io_size, v_io_wdata, io_done_seen,
                         io_read_do, io_write_do, io_read_done, io_write_done);
            end
        end else begin
            io_stk_cnt <= 0;
        end
    end
`endif

    // -------------------------------------------------------- interrupt adapter
    assign interrupt_done  = v_inta;       // Ventium INTA pulse → PIC ack

    // -------------------------------------------------------- the Ventium core
    // R2 (PS->PL coherence): the daemon writes guest RAM via mmap over HP0 (non-coherent), which never
    // snoops the FPGA L1D. It toggles dbg_cmp[63] (mgmt DBG_CMP_RANGE bit 31) after each DDR service and
    // before x86_poll; sync into the core clock and edge-detect a 1-cycle flush_all pulse so the L1D drops
    // any line stale w.r.t. that PS write. !VEN_DBG_CORE (dbg_cmp absent) -> flush off (old behavior).
`ifdef VEN_DBG_CORE
    logic fl_s0, fl_s1, fl_prev; logic l1_flush_pulse;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fl_s0<=1'b0; fl_s1<=1'b0; fl_prev<=1'b0; end
        else begin fl_s0<=dbg_cmp[63]; fl_s1<=fl_s0; fl_prev<=fl_s1; end
    end
    assign l1_flush_pulse = fl_s1 ^ fl_prev;
`else
    wire l1_flush_pulse = 1'b0;
`endif

    // Opt-in only for the tested ao486 cache/Avalon backend. Do not use this
    // as a global HP/HPC workaround override: narrow replay is independent,
    // and direct PS-port integrations retain their existing line policy.
`ifdef VEN_AO486_SINGLE_FILL
    localparam bit AO486_LINE_REPLAY = 1'b0;
`else
    localparam bit AO486_LINE_REPLAY = 1'b1;
`endif
    ventium_top #(.AXI_LINE_REPLAY(AO486_LINE_REPLAY)) u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_eip   (32'h0),
        .init_esp   (32'h0),
        .boot_mode  (1'b1),                // system mode: reset @ F000:FFF0 real mode
        .bus_mode   (1'b0),                // use L1+AXI, not the pin-bus exerciser
        .cycle_mode (1'b1),                // dual U/V issue (real P5)
        .errata_en  (5'h0),                // clean core
        .cpu_hung   (v_cpu_hung),
        // M7 syscall proxy — off (real system boot, not user-mode lockstep)
        .proxy_en   (1'b0),
        .syscall_active(), .syscall_n(),
        .syscall_resume_eip(32'h0), .syscall_eax(32'h0),
        .syscall_apply_gs(1'b0), .syscall_gs_base(32'h0),
        .syscall_arg_eax(), .syscall_arg_ebx(), .syscall_arg_ecx(), .syscall_arg_edx(),
        .syscall_arg_esi(), .syscall_arg_edi(), .syscall_arg_ebp(),
        // port I/O
        .cosim_en   (1'b1),
        .io_req     (v_io_req), .io_we(v_io_we), .io_addr(v_io_addr),
        .io_size    (v_io_size), .io_wdata(v_io_wdata),
        .io_rdata   (v_io_rdata), .io_ack(v_io_ack),
        // mem BFM port — inert when l1axi_en=1
        .mem_req(), .mem_we(), .mem_addr(), .mem_wdata(), .mem_wstrb(),
        .mem_rdata  (32'h0), .mem_ack(1'b0),
        // L1 + AXI master
        .l1axi_en   (1'b1),
        .flush_all  (l1_flush_pulse),      // R2: daemon-toggled PS->PL coherence flush (dbg_cmp[63] edge)
        .golden_l1  (1'b0),   // build #28: golden DISABLED. Build #27 PROVED the corruption is a downstream
                              // read-response mis-sync (HP0 fill of 0x700 returns stale QUAKE/WIN95 dirents),
                              // NOT L1D staleness. golden's ~0x600 per-byte re-fills only STRESS that mis-sync.
                              // Reverting to the proven ao486 path: golden off + L2 enabled + no barrier.
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock),
        .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock),
        .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .bus_err(v_bus_err), .shutdown(1'b0), .m_idle(v_m_idle),
        // KV260 observability + external interrupt seam
        .retire_count(v_retire_count),
        .soc_en     (1'b1),
        .intr       (interrupt_do),
        .inta_vector(interrupt_vector),
        .inta       (v_inta)
        // ---- debug bundle (VEN_DBG_CORE): the ports exist only under VEN_DBG_CORE, so the
        // connections + packing are gated too — a non-debug build (e.g. the cosim) is untouched.
`ifdef VEN_DBG_CORE
        , .dbg_retire_valid(d_retire_valid), .dbg_eip(d_eip), .dbg_cs(d_cs), .dbg_esp(d_esp),
        .dbg_eflags(d_eflags), .dbg_state(d_state), .dbg_int_vec(d_int_vec), .dbg_fault_pc(d_fault_pc),
        .dbg_cr0(d_cr0), .dbg_rd_valid(d_rd_valid), .dbg_rd_addr(d_rd_addr), .dbg_rd_data(d_rd_data),
        .dbg_cmp_cfg(dbg_cmp[31:0]), .dbg_cmp_range(dbg_cmp[63:32]), .dbg_cmp_freeze(d_cmp_freeze),
        .dbg_halt_req(dbg_cmp[64]), .dbg_step(dbg_cmp[65]), .dbg_bp_en(dbg_cmp[66]),
        .dbg_bp_addr(dbg_cmp[98:67]), .dbg_bp_clr(dbg_cmp[99]),
        .dbg_arch_sel(dbg_cmp[106:100]), .dbg_arch_data(d_arch_data), .dbg_halted(d_halted)
`endif
    );
`ifdef VEN_DBG_CORE
    // debug taps + pack into dbg_bus (layout documented at the port)
    logic        d_retire_valid, d_rd_valid, d_cmp_freeze, d_halted;
    logic [31:0] d_eip, d_esp, d_eflags, d_fault_pc, d_cr0, d_rd_addr, d_rd_data, d_arch_data;
    logic [15:0] d_cs;
    logic [5:0]  d_state;
    logic [7:0]  d_int_vec;
    assign dbg_bus = { d_arch_data, d_halted, d_cmp_freeze, d_rd_data, d_rd_addr, d_rd_valid, d_cr0, d_fault_pc,
                       d_int_vec, d_state, d_eflags, d_esp, d_cs, d_eip, d_retire_valid, v_inta };
`ifndef SYNTHESIS
    // Stall watchdog (sim-only): if the core goes many cycles without a retire,
    // dump the FSM/fault taps so a livelock is diagnosable from the log.
    integer stall_n;
    always @(posedge clk) begin
        if (!rst_n) stall_n <= 0;
        else if (d_retire_valid) stall_n <= 0;
        else begin
            stall_n <= stall_n + 1;
            if (stall_n == 1000000 || (stall_n > 1000000 && (stall_n % 5000000) == 0))
                $display("[STALL] no retire for %0d cyc: state=%0d cs=%04x:eip=%08x fault_pc=%08x int_vec=%02x cr0=%08x rd_v=%b rd_addr=%08x",
                         stall_n, d_state, d_cs, d_eip, d_fault_pc, d_int_vec, d_cr0, d_rd_valid, d_rd_addr);
        end
    end
`endif
`else
    assign dbg_bus = 291'd0;
`endif

    // ---------------------------------------------- AXI4 → Avalon bridge (+A20/remap)
    ven_axi2avalon u_bridge (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(m_awid), .s_axi_awaddr(a20_remap(m_awaddr)), .s_axi_awlen(m_awlen),
        .s_axi_awsize(m_awsize), .s_axi_awburst(m_awburst),
        .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wlast(m_wlast),
        .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
        .s_axi_bid(m_bid), .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
        .s_axi_arid(m_arid), .s_axi_araddr(a20_remap(m_araddr)), .s_axi_arlen(m_arlen),
        .s_axi_arsize(m_arsize), .s_axi_arburst(m_arburst),
        .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
        .s_axi_rid(m_rid), .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp),
        .s_axi_rlast(m_rlast), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
        .avm_address(avm_address), .avm_writedata(avm_writedata),
        .avm_byteenable(avm_byteenable), .avm_burstcount(avm_burstcount),
        .avm_write(avm_write), .avm_read(avm_read),
        .avm_waitrequest(avm_waitrequest), .avm_readdatavalid(avm_readdatavalid),
        .avm_readdata(avm_readdata)
    );

`ifdef VEN_IO_DBG
    // Diagnostic (CORRECT address latch): io_read_address changes by the time io_read_done
    // fires, so match the address at the REQUEST edge. Counts 0x3DA reads Ventium completes
    // and how many delivered bit3=1. If bit3set/reads is ~0 the poll never receives the
    // retrace (capture drops it); if it is significant the poll SHOULD catch it (bug is
    // elsewhere). Compare vs the VGA side (VEN_VGA_DBG) sticky-set-read count.
    reg [15:0] io_lat_addr; reg io_active;
    integer io3da_dbg = 0, io3da_hit = 0;
    always @(posedge clk) if(rst_n) begin
        if((io_read_do | io_write_do) & ~io_active) begin io_lat_addr <= io_read_address; io_active <= 1'b1; end
        if(io_read_done | io_write_done) begin
            io_active <= 1'b0;
            if(io_lat_addr == 16'h03DA && io_read_done) begin
                io3da_dbg = io3da_dbg + 1;
                if(io_read_data[3]) io3da_hit = io3da_hit + 1;
                if(io3da_dbg<=8 || io3da_dbg%100000==0)
                    $display("[IO-DBG] 0x3DA reads=%0d bit3=1_delivered=%0d (last data=%02x)",
                             io3da_dbg, io3da_hit, io_read_data[7:0]);
            end
        end
    end
`endif

endmodule
