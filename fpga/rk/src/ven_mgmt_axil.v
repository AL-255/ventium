// ven_mgmt_axil.v — AXI4-Lite slave that gives the PS daemon the ao486_MiSTer HPS `mgmt_*`
// bus (BIOS/ROM load, disk PIO, CMOS) + core control/status. Faces M_AXI_HPM0_FPD @ 0xA000_0000.
//
// mgmt protocol (authoritative: 3rd-party/ao486_MiSTer/rtl/soc/ide.v):
//   * write : mgmt_write=1 + mgmt_address + mgmt_writedata -> addressed reg; buffer index (addr
//             low-nibble 0xF) advances on the mgmt_write FALLING edge, so a clean 1-cycle pulse.
//   * read  : set mgmt_address; mgmt_readdata (registered) reflects it 1 clock later.
//
// Register map (32-bit, base 0xA000_0000). ALL registers at 0x10-aligned (lane-0) offsets:
//   on the RK BD the AXI4(HPM0)->AXI-Lite path only forwards the lane-0 32-bit word (byte
//   addr[3:2]==00); offsets in lanes 1/2/3 (0x04/0x08/0x0C/0x14/0x18/0x1C ...) DROP on write and
//   read back 0 (verified on hardware). So every register sits at a 0x10 multiple:
//   0x00 IDENT   RO 0xA0486V01
//   0x10 MGMT_A  RW -> mgmt_address[3:0] (held)
//   0x20 CTRL    RW [0]CORE_RESET(hold) [1]RUN [8]IRQ_EN
//   0x30 MGMT_WD WO write -> mgmt_writedata + a 1-cycle mgmt_write pulse
//   0x40 MGMT_RD RO read  -> pulse mgmt_read, return settled mgmt_readdata[15:0]
//   0x50 STATUS  RO [2:0]ide0_req [5:3]ide1_req [7:6]fdd_req [8]core_running [9]cpu_hung
//   0x60 DBG     RO mem-path observability (dbg_word from rk_ao486_system_pl)
//
// SECOND BANK at 0x100+ (perf counters). The 16 lane-0 slots 0x00-0xF0 are full and lanes 1/2/3
// are unusable on this BD (see above). A hardware probe showed reads at 0x100 and 0x200 returning
// IDENT -- addr[11:8] was being ignored while the transaction still reached this module -- so the
// read decode is now [11:0] and 0x100+ is a fresh bank of lane-0 registers:
//   0x100/0x110 perf_cyc lo/hi      0x120/0x130 perf_retired lo/hi
//   0x140 perf_io (S_IO cycles)     0x150 perf_irq (external interrupts acked)
//   0x200 snapshot capability       0x210..0x270 frozen context frame
//   0x280 execution control/status  0x290 breakpoint EIP
//   0x2A0 architectural selector    0x2B0 selected architectural word
//   0x2C0 execution-debug capability
//   0x380 keyboard byte submit (WO, bit8=submit, bits7:0=raw Set-2 byte)
//   0x390 keyboard transport status  0x3A0 keyboard transport capability
//   0x400..0x4A0 hosted mouse mailboxes (ven_ps2_mailbox ABI 1)
`default_nettype wire
module ven_mgmt_axil #(parameter ADDR_W = 16)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- AXI4-Lite slave ----
    input  wire [ADDR_W-1:0] s_awaddr, input wire s_awvalid, output reg s_awready,
    input  wire [31:0]       s_wdata,  input wire [3:0] s_wstrb, input wire s_wvalid, output reg s_wready,
    output reg  [1:0]        s_bresp,  output reg s_bvalid, input wire s_bready,
    input  wire [ADDR_W-1:0] s_araddr, input wire s_arvalid, output reg s_arready,
    output reg  [31:0]       s_rdata,  output reg [1:0] s_rresp, output reg s_rvalid, input wire s_rready,
    // ---- mgmt_* bus (to `system`) ----
    output reg  [15:0]  mgmt_address,
    output reg          mgmt_read,
    input  wire [15:0]  mgmt_readdata,
    output reg          mgmt_write,
    output reg  [15:0]  mgmt_writedata,
    // ---- disk request + core control/status ----
    input  wire [2:0]   ide0_request,
    input  wire [2:0]   ide1_request,
    input  wire [1:0]   fdd_request,
    input  wire         cpu_hung,
    input  wire [31:0]  dbg_word,       // mem-path observability (read @ 0x60)
    input  wire [31:0]  dbg_word2,      // last fetch address (read @ 0x70)
    // ---- ven_soc_dbg control (out) + readback (in) — the on-die forensic trace block ----
    output reg  [6:0]   dbg_trace_idx,  // PC/rd ring read index (0=newest); 7b for DEPTH=128
    output reg          dbg_clear,      // W1P: zero perf + clear freeze/rings
    output reg          dbg_ext_freeze, // W1P: freeze the rings NOW
    output reg  [31:0]  dbg_freeze_thresh, // stall cycles -> auto-freeze (0=off)
    output reg  [31:0]  dbg_cmp_cfg,    // retire comparator {eip_care,cs_care,en, match_cs[15:0]}
    output reg  [31:0]  dbg_cmp_range,  // {eip_hi[15:0], eip_lo[15:0]}
    // Quiescent execution controls.  These drive the core's S_DECODE/S_PIPE/
    // S_HLTWAIT boundary park/step/breakpoint logic; they never gate clocks
    // or turn a forensic freeze (which intentionally resets the guest) into a
    // pseudo-pause.
    output reg          dbg_halt_req,
    output reg          dbg_step,        // W1P
    output reg          dbg_bp_en,
    output reg  [31:0]  dbg_bp_addr,
    output reg          dbg_bp_clr,      // W1P
    output reg  [6:0]   dbg_arch_sel,
    input  wire         dbg_halted,
    input  wire [31:0]  dbg_arch_data,
    input  wire [31:0]  dbg_last_eip,
    input  wire         dbg_frozen,
    input  wire [31:0]  dbg_frozen_eip,
    // Versioned freeze-context frame.  These are latched in ven_soc_dbg at
    // the same forensic-freeze event, rather than sampling reset-cleared live
    // core outputs after the PS notices the stop.
    input  wire [31:0]  dbg_frozen_ctx_eip,
    input  wire [15:0]  dbg_frozen_cs,
    input  wire [31:0]  dbg_frozen_esp,
    input  wire [31:0]  dbg_frozen_eflags,
    input  wire [31:0]  dbg_frozen_fault_pc,
    input  wire [31:0]  dbg_frozen_cr0,
    input  wire [5:0]   dbg_frozen_state,
    input  wire [7:0]   dbg_frozen_vec,
    input  wire [31:0]  dbg_trace_pc,
    input  wire [31:0]  dbg_trace_aux,
    input  wire [5:0]   dbg_trace_count,
    input  wire [31:0]  dbg_rd_ring_addr,
    input  wire [31:0]  dbg_rd_ring_data,
    input  wire [31:0]  dbg_rd_ring_data_hi,
    input  wire [31:0]  dbg_perf_stall,
    input  wire [63:0]  dbg_perf_cyc,      // total cycles since clear   (read @ 0x04/0x08)
    input  wire [63:0]  dbg_perf_retired,  // retired instrs since clear (read @ 0x0C/0x14)
    input  wire [31:0]  dbg_perf_io,       // cycles parked in S_IO      (read @ 0x18)
    input  wire [31:0]  dbg_perf_irq,      // external interrupts acked  (read @ 0x150)
    input  wire [31:0]  dbg_cr0_live,      // live CR0 (bit30=CD, bit29=NW) (read @ 0x160)
    input  wire [31:0]  dbg_rd_beats,      // accepted AXI read beats      (read @ 0x170)
    input  wire [31:0]  dbg_ar_hs,         // AR handshakes (bursts, incl priming) (read @ 0x180)
    input  wire [31:0]  dbg_b_hs,          // write responses              (read @ 0x190)
    // Passive outer-read latency counters.  These occupy the two historical
    // state bins whose hard-coded enum values are invalid for the deployed
    // feature profile.  They are observation-only and have no control path.
    input  wire [31:0]  dbg_st_pipe,       // AR..RLAST occupancy cycles   (read @ 0x1A0)
    input  wire [31:0]  dbg_st_walk,       // AR..first-R latency cycles   (read @ 0x1B0)
    input  wire [31:0]  dbg_st_fetch,      // cycles in S_FETCH            (read @ 0x1C0)
    input  wire [31:0]  dbg_st_other,      // cycles in every other state  (read @ 0x1D0)
    // ---- passive VGA-frame recorder ---------------------------------------
    // CAP_CTL/ADDR live in the write bank; CAP_DATA is a synchronous BRAM
    // read and therefore takes the R_WAIT path below.  This interface has no
    // path back into the VGA or CPU.
    output reg          cap_arm,            // W1P @ 0x300, starts next VSYNC frame
    output reg  [16:0]  cap_rd_addr,        // word address, written @ 0x360
    output reg          cap_rd_en,          // internal one-cycle BRAM read pulse
    input  wire [31:0]  cap_rd_data,
    input  wire         cap_frame_ready,
    input  wire         cap_capture_active,
    input  wire         cap_frame_overrun,
    input  wire [31:0]  cap_frame_sequence,
    input  wire [63:0]  cap_frame_cycle,
    input  wire [11:0]  cap_frame_width,
    input  wire [11:0]  cap_frame_height,
    input  wire [19:0]  cap_frame_pixels,
    // ---- hosted PS/2 keyboard device -------------------------------------
    // A narrow external-device transport.  Raw Set-2 bytes are accepted only
    // on the W1P submit at 0x380; guest memory and CPU control are untouched.
    output reg  [7:0]   kbd_inject_data,
    output reg          kbd_inject_valid,
    input  wire         kbd_inject_ready,
    input  wire         kbd_inject_busy,
    // One-cycle registered writes; all four byte strobes reach the mailbox.
    // The current read address selects combinational mailbox data, which the
    // ordinary AXI read FSM captures and retains under R-channel backpressure.
    output reg          mouse_csr_write,
    output reg [3:0]    mouse_csr_waddr,
    output reg [31:0]   mouse_csr_wdata,
    output reg [3:0]    mouse_csr_wstrb,
    output wire [3:0]   mouse_csr_raddr,
    input wire [31:0]   mouse_csr_rdata,
    output reg          core_reset_n,
    output reg          irq_out
);
    localparam IDENT = 32'hA0486501;
    // Read @0x200 advertises that 0x210..0x270 are a coherent freeze-time
    // context frame.  A separate capability marker avoids an old bitstream's
    // zero-filled unused reads being mistaken for valid architectural state.
    localparam DBG_SNAPSHOT_CAP = 32'h5644_0001; // "VD", format 1
    // Format 5 adds the latched stop cause after the format-4 debug-register
    // and hidden task/LDT-cache words.  It lets a halted scan distinguish a
    // completed STEP from the manual halt level which re-parks that step.
    // Do not leave this at format 1:
    // an old image would truncate high selectors and fabricate a misleading
    // state dump.
    localparam DBG_EXEC_CAP = 32'h5645_0005;     // "VE", format 5
    localparam KBD_INJECT_CAP = 32'h564B_0001;   // "VK", format 1
    reg [15:0] ctrl;
    assign mouse_csr_raddr = s_araddr[7:4];

    // ---- write channel FSM (handles the mgmt_write pulse) ----
    localparam [1:0] W_IDLE=0, W_PULSE=1, W_RESP=2;
    reg [1:0] wst;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_awready<=0; s_wready<=0; s_bvalid<=0; s_bresp<=0; wst<=W_IDLE;
            mgmt_write<=0; mgmt_writedata<=0; mgmt_address<=0; ctrl<=16'h0001; // CORE_RESET=1 at reset
            core_reset_n<=0;
            dbg_trace_idx<=0; dbg_clear<=0; dbg_ext_freeze<=0; dbg_freeze_thresh<=0;
            dbg_cmp_cfg<=0; dbg_cmp_range<=0;
            dbg_halt_req<=0; dbg_step<=0; dbg_bp_en<=0; dbg_bp_addr<=0; dbg_bp_clr<=0; dbg_arch_sel<=0;
            cap_arm<=0; cap_rd_addr<=0;
            kbd_inject_data<=0; kbd_inject_valid<=0;
            mouse_csr_write<=0; mouse_csr_waddr<=0; mouse_csr_wdata<=0; mouse_csr_wstrb<=0;
        end else begin
            s_awready<=0; s_wready<=0; mgmt_write<=0; dbg_clear<=0; dbg_ext_freeze<=0;
            dbg_step<=0; dbg_bp_clr<=0; cap_arm<=0; kbd_inject_valid<=0; // W1P defaults
            mouse_csr_write<=0;
            case (wst)
                W_IDLE: if (s_awvalid && s_wvalid) begin
                    s_awready<=1; s_wready<=1;
                    if (s_awaddr[11:8] == 4'h4 && s_awaddr[3:0] == 4'h0) begin
                        mouse_csr_write <= 1;
                        mouse_csr_waddr <= s_awaddr[7:4];
                        mouse_csr_wdata <= s_wdata;
                        mouse_csr_wstrb <= s_wstrb;
                    end
                    // Full 12-bit bank decode is essential: a write to the
                    // 0x2xx execution debugger must never alias a legacy
                    // 0x0xx command (in particular, STEP must not look like
                    // DBG_CTL bit8=CLEAR).  The board's lane limitation is
                    // about addr[3:2], not an excuse to discard addr[11:8].
                    case (s_awaddr[11:0])
                        12'h020: ctrl           <= s_wdata[15:0];  // CTRL
                        12'h010: mgmt_address   <= s_wdata[15:0];  // MGMT_A
                        12'h030: begin mgmt_writedata <= s_wdata[15:0]; mgmt_write <= 1'b1; end  // MGMT_WD
                        12'h080: begin dbg_trace_idx <= s_wdata[6:0]; dbg_clear <= s_wdata[8]; dbg_ext_freeze <= s_wdata[16]; end // DBG_CTL
                        12'h090: dbg_freeze_thresh <= s_wdata;      // DBG_THRESH
                        12'h0A0: dbg_cmp_cfg   <= s_wdata;          // DBG_CMP_CFG
                        12'h0B0: dbg_cmp_range <= s_wdata;          // DBG_CMP_RANGE
                        12'h300: cap_arm       <= s_wdata[0];       // CAP_CTL W1P
                        12'h360: cap_rd_addr   <= s_wdata[16:0];    // CAP_ADDR (word)
                        12'h380: begin
                            kbd_inject_data  <= s_wdata[7:0];
                            kbd_inject_valid <= s_wdata[8] & kbd_inject_ready;
                        end
                        default: ;
                    endcase
                    // Debug execution is deliberately separate from the
                    // forensic freeze block.  Bit 0/1 are held levels;
                    // bit 8/9 are single-clock commands.
                    case (s_awaddr[11:0])
                        12'h280: begin
                            dbg_halt_req <= s_wdata[0];
                            dbg_bp_en    <= s_wdata[1];
                            dbg_step     <= s_wdata[8];
                            dbg_bp_clr   <= s_wdata[9];
                        end
                        12'h290: dbg_bp_addr  <= s_wdata;
                        12'h2A0: dbg_arch_sel <= s_wdata[6:0];
                        default: ;
                    endcase
                    wst <= (s_awaddr[11:0]==12'h030) ? W_PULSE : W_RESP;
                end
                W_PULSE: begin mgmt_write<=1'b1; wst<=W_RESP; end
                W_RESP: begin s_bvalid<=1; s_bresp<=0; if (s_bvalid && s_bready) begin s_bvalid<=0; wst<=W_IDLE; end end
            endcase
            core_reset_n <= ctrl[1] & ~ctrl[0];   // RUN & !CORE_RESET
        end
    end

    // ---- read channel FSM (handles the mgmt_read settle) ----
    localparam [1:0] R_IDLE=0, R_WAIT=1, R_RESP=2;
    reg [1:0] rst2; reg [1:0] rwait; reg r_cap;
    wire [31:0] status_w = {6'd0, cpu_hung, ctrl[1] /*running*/, fdd_request, ide1_request, ide0_request};
    always @(posedge clk) begin
        if (!rst_n) begin
            s_arready<=0; s_rvalid<=0; s_rresp<=0; s_rdata<=0; rst2<=R_IDLE; mgmt_read<=0; irq_out<=0;
            r_cap<=0; cap_rd_en<=0;
        end else begin
            s_arready<=0; mgmt_read<=0; cap_rd_en<=0;
            irq_out <= (|ide0_request | |ide1_request | |fdd_request) & ctrl[8]; // IRQ_EN=ctrl[8]
            case (rst2)
                R_IDLE: if (s_arvalid) begin
                    s_arready<=1;
                    if (s_araddr[11:0]==12'h040) begin mgmt_read<=1'b1; rwait<=2'd2; r_cap<=0; rst2<=R_WAIT; end  // MGMT_RD
                    else if (s_araddr[11:0]==12'h370) begin cap_rd_en<=1'b1; rwait<=2'd1; r_cap<=1; rst2<=R_WAIT; end // CAP_DATA
                    else begin
                        r_cap<=0;
                        case (s_araddr[11:0])         // lane-0 (0x10-aligned); 0x000-0x0F0 legacy, 0x100+ perf
                            12'h000: s_rdata<=IDENT;                    // IDENT
                            12'h050: s_rdata<=status_w;                 // STATUS
                            12'h020: s_rdata<={16'd0,ctrl};             // CTRL
                            12'h010: s_rdata<={16'd0,mgmt_address};     // MGMT_A
                            12'h060: s_rdata<=dbg_word;                 // DBG (mem-path counters)
                            12'h070: s_rdata<=dbg_word2;                // DBG2 (last fetch address)
                            // ---- ven_soc_dbg forensic readback (PC ring + freeze + rd-beat) ----
                            12'h080: s_rdata<=dbg_last_eip;             // last retired EIP
                            12'h090: s_rdata<={dbg_frozen,7'd0,dbg_frozen_vec,2'd0,dbg_frozen_state,2'd0,dbg_trace_count}; // freeze info
                            12'h0A0: s_rdata<=dbg_frozen_eip;           // EIP at freeze
                            12'h0B0: s_rdata<=dbg_trace_pc;             // PC ring[idx].eip
                            12'h0C0: s_rdata<=dbg_trace_aux;            // PC ring[idx].{state,cs}
                            12'h030: s_rdata<=dbg_rd_ring_data_hi;      // rd-beat ring[idx].data[63:32] (0x30 write=MGMT_WD; read free)
                            12'h0D0: s_rdata<=dbg_rd_ring_addr;         // rd-beat ring[idx].addr
                            12'h0E0: s_rdata<=dbg_rd_ring_data;         // rd-beat ring[idx].data[31:0]
                            12'h0F0: s_rdata<=dbg_perf_stall;           // stall cycles
                            // ---- PERF counters (task #24 / bug#7-reclassified-to-perf) -------------
                            // ven_soc_dbg has ALWAYS computed these; pl.v left them unconnected, so the
                            // one number that matters for a performance problem -- IPC -- was not
                            // measurable on hardware at all.
                            // PLACEMENT: lanes 1/2/3 (0x04/0x08/...) are NOT usable -- the RK BD's
                            // AXI4->AXI-Lite path drops them (header above; re-verified on hardware:
                            // 0x004 and 0x00C both read back 00000000). The 16 lane-0 slots 0x00-0xF0
                            // are all taken. BUT a hardware probe showed 0x100 and 0x200 both return
                            // IDENT, i.e. addr[11:8] was simply ignored while the transaction DID
                            // reach this module. So widening the decode to [11:0] opens a fresh bank
                            // of lane-0 registers at 0x100+, which is what these use.
                            // IPC = retired/cyc; stall/cyc and io/cyc partition where cycles went.
                            12'h100: s_rdata<=dbg_perf_cyc[31:0];
                            12'h110: s_rdata<=dbg_perf_cyc[63:32];
                            12'h120: s_rdata<=dbg_perf_retired[31:0];
                            12'h130: s_rdata<=dbg_perf_retired[63:32];
                            12'h140: s_rdata<=dbg_perf_io;           // cycles parked in S_IO
                            12'h150: s_rdata<=dbg_perf_irq;          // external interrupts acked
                            // Live CR0. bit30=CD, bit29=NW. A 486 comes out of reset with CD=1
                            // (caches disabled); if the BIOS never clears it, VEN_L1_HONOR_CD makes
                            // every store a non-allocating write-through to PS DDR on a
                            // single-outstanding AXI backing -- i.e. each store eats a full round
                            // trip. That is a candidate explanation for the measured 98.66%
                            // no-retire rate, so CD must be OBSERVED, not assumed.
                            12'h160: s_rdata<=dbg_cr0_live;
                            // task #53: free-running AXI event counts. d(beats)/d(perf_cyc) is the
                            // MEASURED per-beat read cost; d(beats)/d(ar_hs) should be ~8 and tells
                            // "slow to start a burst" apart from "slow between beats".
                            12'h170: s_rdata<=dbg_rd_beats;
                            12'h180: s_rdata<=dbg_ar_hs;
                            12'h190: s_rdata<=dbg_b_hs;
                            // task #54: FSM state cycle bins. UPDATE 248 showed the stall is
                            // core-internal (93.7% stall, ~3% AXI, io=0%); these say WHICH state.
                            12'h1A0: s_rdata<=dbg_st_pipe;
                            12'h1B0: s_rdata<=dbg_st_walk;
                            12'h1C0: s_rdata<=dbg_st_fetch;
                            12'h1D0: s_rdata<=dbg_st_other;
                            // ---- passive VGA frame recorder -----------------------------
                            // Status is stable while READY=1; CAP_DATA is a separate
                            // synchronous BRAM port below, so 0x370 is handled in R_WAIT.
                            12'h310: s_rdata<={cap_frame_overrun, cap_capture_active,
                                                cap_frame_ready, cap_frame_sequence[28:0]};
                            12'h320: s_rdata<=cap_frame_cycle[31:0];
                            12'h330: s_rdata<=cap_frame_cycle[63:32];
                            12'h340: s_rdata<={8'd0, cap_frame_height, cap_frame_width};
                            12'h350: s_rdata<={12'd0, cap_frame_pixels};
                            12'h360: s_rdata<={15'd0, cap_rd_addr};
                            // ---- hosted PS/2 keyboard device --------------------------
                            12'h390: s_rdata<={30'd0,kbd_inject_busy,kbd_inject_ready};
                            12'h3A0: s_rdata<=KBD_INJECT_CAP;
                            12'h400, 12'h410, 12'h420, 12'h430,
                            12'h440, 12'h450, 12'h460, 12'h470,
                            12'h480, 12'h490, 12'h4A0, 12'h4B0,
                            12'h4C0, 12'h4D0, 12'h4E0, 12'h4F0:
                                s_rdata <= mouse_csr_rdata;
                            // ---- versioned forensic context frame -------------------------------
                            // This bank is deliberately read-only.  It adds no command path into the
                            // CPU and is therefore safe for a production-style debug image.
                            12'h200: s_rdata<=DBG_SNAPSHOT_CAP;
                            12'h210: s_rdata<={16'd0,dbg_frozen_cs};
                            12'h220: s_rdata<=dbg_frozen_ctx_eip;
                            12'h230: s_rdata<=dbg_frozen_esp;
                            12'h240: s_rdata<=dbg_frozen_eflags;
                            12'h250: s_rdata<=dbg_frozen_fault_pc;
                            12'h260: s_rdata<=dbg_frozen_cr0;
                            12'h270: s_rdata<={16'd0,dbg_frozen_state,2'd0,dbg_frozen_vec};
                            // ---- quiescent execution debugger ---------------------------------
                            // 0x280: [0]halt request, [1]breakpoint enable, [2]core halted;
                            // writes use [8]step (W1P), [9]breakpoint-clear (W1P).
                            // 0x290: pre-issue EIP breakpoint.  0x2a0 selects the read-only
                            // integer/system word at 0x2b0.  Software must wait for HALTED
                            // before iterating selectors, otherwise this is merely a live probe.
                            12'h280: s_rdata<={29'd0,dbg_halted,dbg_bp_en,dbg_halt_req};
                            12'h290: s_rdata<=dbg_bp_addr;
                            12'h2A0: s_rdata<={25'd0,dbg_arch_sel};
                            12'h2B0: s_rdata<=dbg_arch_data;
                            12'h2C0: s_rdata<=DBG_EXEC_CAP;
                            default: s_rdata<=32'd0;
                        endcase
                        rst2<=R_RESP;
                    end
                end
                R_WAIT: if (r_cap) begin
                    // CAP_DATA: t0 issues cap_rd_en, t1 updates the BRAM
                    // output, and this t2 response sees the settled word.
                    if (rwait==0) begin s_rdata<=cap_rd_data; r_cap<=0; rst2<=R_RESP; end
                    else rwait<=rwait-1'b1;
                end else begin
                    mgmt_read<=1'b1;
                    if (rwait==0) begin s_rdata<={16'd0,mgmt_readdata}; rst2<=R_RESP; end else rwait<=rwait-1'b1;
                end
                R_RESP: begin s_rvalid<=1; s_rresp<=0; if (s_rvalid && s_rready) begin s_rvalid<=0; rst2<=R_IDLE; end end
            endcase
        end
    end
endmodule
`default_nettype wire
