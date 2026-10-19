`default_nettype wire  // added for Vivado project-flow synth (leak-proof; Quartus-style expects wire)
/*
 * Copyright (c) 2020, Alexey Melnikov
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * 
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module ide
(
	input             clk,
	input             rst_n,

	output reg        irq,
	output            drq,

	// Ventium bug#7 DEBUG (task #50): the guest sleeps in a DOS `sti; HLT` loop after a
	// completed read, and the two bits that can suppress the completion IRQ live HERE and
	// are invisible to the PS (ide.v's mgmt read mux, lines ~192-197, returns only
	// sector/cylinder/count/cmd). Both come from one guest write to Device Control
	// (io_address 14 == port 0x3F6): bit1 -> disable_irq (nIEN), bit2 -> sw_reset (SRST),
	// and `reset = ~rst_n | sw_reset` holds the WHOLE device in reset. Export them so the
	// debug block can latch {disable_irq, sw_reset, irq} into FRZINFO's spare bits [30:24].
	// Pure observers — no behavioural change.
	output            dbg_disable_irq,
	output            dbg_sw_reset,
	
	input             use_fast, // 1 - supports fast read mode
	output            no_data,  // pause for system when no data is available in fast mode

	output      [1:0] drive_en,

	input       [3:0] io_address,
	input             io_read,
	output reg [31:0] io_readdata,
	input             io_write,
	input      [31:0] io_writedata,
	input             io_32,

	output reg        io_wait,

	output reg  [2:0] request,

	input       [3:0] mgmt_address,
	input             mgmt_write,
	input      [15:0] mgmt_writedata,
	input             mgmt_read,
	output reg [15:0] mgmt_readdata
);

assign drq      = status[3];
assign drive_en = present;

//------------------------------------------------------------------------------

wire io_wr = io_write & |present;

//------------------------------------------------------------------------------

always @(posedge clk) if(io_read) begin
	if(!present) io_readdata <= 32'hFFFFFFFF;
	else begin
		case(io_address)
				   0: io_readdata <= status[3] ? {buf_q[31:16], (~io_32 & io_cnt[0]) ? buf_q[31:16] : buf_q[15:0]} : 32'd0;
				   1: io_readdata <= error;
				   2: io_readdata <= (hob ? sector_count[15:8] : sector_count[7:0] );
				   3: io_readdata <= (hob ? sector[15:8]       : sector[7:0]       );
				   4: io_readdata <= (hob ? cylinder[23:16]    : cylinder[7:0]     );
				   5: io_readdata <= (hob ? cylinder[31:24]    : cylinder[15:8]    );
				   6: io_readdata <= drv_addr;
				   7: io_readdata <= status;
				  14: io_readdata <= status;
				  15: io_readdata <= { 2'b10, ~drv_addr[3:0], ~drv_addr[4], drv_addr[4]};
			default: io_readdata <= 0;
		endcase
	end
end

//------------------------------------------------------------------------------

reg [7:0] features;
always @(posedge clk) begin
	if(~rst_n)                               features <= 8'h00;
	else if(io_wr && io_address == 1)        features <= io_writedata[7:0];
end

reg [15:0] blk_size;
always @(posedge clk) begin
	if(~rst_n)                                               blk_size <= 16'h0000;
	else if(mgmt_write && mgmt_address == 0)                 blk_size <= {mgmt_writedata[7:0], 8'h00};
	else if(mgmt_write && mgmt_address == 4 && blk_size[15]) blk_size <= mgmt_writedata[15:0];
end

reg [7:0] error;
always @(posedge clk) begin
	if(~rst_n)                               error <= 8'h00;
	else if(mgmt_write && mgmt_address == 0) error <= mgmt_writedata[15:8];
end

reg [15:0] sector_count;
always @(posedge clk) begin
	if(~rst_n)                               sector_count       <= 16'd1;
	else if(mgmt_write && mgmt_address == 1) sector_count[7:0]  <= mgmt_writedata[7:0];
	else if(mgmt_write && mgmt_address == 3) sector_count[15:8] <= mgmt_writedata[7:0];
	else if(io_wr && io_address == 2)        sector_count       <= {sector_count[7:0], io_writedata[7:0]};
end

reg [15:0] sector;
always @(posedge clk) begin
	if(~rst_n)                               sector       <= 16'd1;
	else if(mgmt_write && mgmt_address == 1) sector[7:0]  <= mgmt_writedata[15:8];
	else if(mgmt_write && mgmt_address == 3) sector[15:8] <= mgmt_writedata[15:8];
	else if(io_wr && io_address == 3)        sector       <= {sector[7:0],io_writedata[7:0]};
end

reg [31:0] cylinder;
always @(posedge clk) begin
	if(~rst_n)                               cylinder                          <= 32'hFFFFFFFF;
	else if(mgmt_write && mgmt_address == 2) cylinder[15:0]                    <= mgmt_writedata[15:0];
	else if(mgmt_write && mgmt_address == 4) cylinder[31:16]                   <= mgmt_writedata[15:0];
	else if(io_wr && io_address == 4)        {cylinder[23:16], cylinder[7:0] } <= {cylinder[7:0],  io_writedata[7:0]};
	else if(io_wr && io_address == 5)        {cylinder[31:24], cylinder[15:8]} <= {cylinder[15:8], io_writedata[7:0]};
end

reg [7:0] drv_addr;
always @(posedge clk) begin
	if(~rst_n)                               drv_addr <= 8'd0;
	else if(mgmt_write && mgmt_address == 5) drv_addr <= mgmt_writedata[7:0];
	else if(io_wr && io_address == 6)        drv_addr <= io_writedata[7:0];
end

reg [7:0] cmd;
always @(posedge clk) begin
	if(~rst_n)                               cmd <= 8'd0;
	else if(io_wr && io_address == 7)        cmd <= io_writedata[7:0];
end

reg [7:0] status = 0;
always @(posedge clk) begin
	if(reset)                                status <= 8'h80;
	else if(mgmt_write && mgmt_address == 5) status <= {mgmt_writedata[15:14],1'b0,mgmt_writedata[12:11],2'b00,mgmt_writedata[8]};
	else if(io_wr && io_address == 7)        status <= 8'h80;
	// `io_done` remains high until the daemon publishes the next block through
	// mgmt word 5.  Treating that level as a completion in several independent
	// always blocks races the terminal bit: one block clears last_read while
	// another decides whether to request another block.  Consume one owned
	// completion edge instead, so status and request use the same terminal
	// classification for the whole completed transfer.
	// A terminal PIO block only withdraws DRQ.  Preserve the published drive
	// state (in particular DRDY/DSC): hard-coding 40h discarded valid ATA
	// state and made a ready/seek-complete drive look partially not-ready.
	else if(block_done_pending & block_done_last) status <= block_done_status;
	else if(block_done_pending)                   status <= 8'h80;
end

reg last_read = 0;
always @(posedge clk) begin
	if(reset)                                last_read <= 0;
	else if(mgmt_write && mgmt_address == 5) last_read <= mgmt_writedata[9];
	else if(block_done_pending)              last_read <= 0;
end

reg fast_read = 0;
always @(posedge clk) begin
	if(reset)                                fast_read <= 0;
	else if(mgmt_write && mgmt_address == 5) fast_read <= mgmt_writedata[13];
	else if(block_done_pending)              fast_read <= 0;
end

always @(posedge clk) begin
	if(~rst_n)                               io_wait <= 1'd0;
	else if(sw_reset)                        io_wait <= use_wait;
	else if(mgmt_write && mgmt_address == 5) io_wait <= 1'd0;
	else if(io_wr && io_address == 7)        io_wait <= use_wait;
	else if(block_done_pending)              io_wait <= use_wait;
end

always @(posedge clk) begin
	if(reset)                                request <= 3'b110; // reset
	else if(mgmt_write && mgmt_address == 5) request <= 3'b000;
	else if(io_wr && io_address == 7)        request <= 3'b100; // new command 
	else if(block_done_pending & ~block_done_last) request <= 3'b101; // data send/recv
end

always @(posedge clk) begin
	// Word 5 owns IRQ publication, including backend WRITE completion.
	// Draining a data-in buffer is not a second completion interrupt: after
	// regular status acknowledges its data-ready IRQ, it must stay cleared.
	if(reset)                                                                      irq <= 1'b0;
	else if(mgmt_write && mgmt_address == 5 && mgmt_writedata[10] && ~disable_irq) irq <= 1'b1;
	else if((io_read | io_wr) && io_address == 7)                                  irq <= 1'b0;
end

always @(posedge clk) begin
	case(mgmt_address)
			0: mgmt_readdata <= {features, 6'd0, use_fast, io_done};
			1: mgmt_readdata <= {sector[7:0], sector_count[7:0]};
			2: mgmt_readdata <= {cylinder[15:0]};
			3: mgmt_readdata <= {sector[15:8], sector_count[15:8]};
			4: mgmt_readdata <= {cylinder[31:16]};
			5: mgmt_readdata <= {cmd, drv_addr};
			// VEN bug#7 (task #50): IRQ-suppression state, otherwise INVISIBLE to the PS.
			// The guest sleeps in a DOS `sti; HLT` loop after a COMPLETED read, so the
			// question is whether the completion IRQ was raised, masked, or gated away.
			// Both suppressors come from one guest write to Device Control (io_address 14
			// == port 0x3F6): bit1 -> disable_irq (nIEN), bit2 -> sw_reset (SRST, which
			// gates the WHOLE device via reset = ~rst_n | sw_reset). Read-only observers.
			// Layout: [0]=irq  [1]=disable_irq(nIEN)  [2]=sw_reset(SRST)
			6: mgmt_readdata <= {13'd0, sw_reset, disable_irq, irq};
			8: mgmt_readdata <= ven_dbg_w0;     // VEN DIAG: io_readdata @word0 (expect 0040)
			9: mgmt_readdata <= ven_dbg_w1;     // VEN DIAG: io_readdata @word1 cyl (expect 001f)
		   10: mgmt_readdata <= ven_dbg_w3;     // VEN DIAG: io_readdata @word3 heads (expect 0010)
		   11: mgmt_readdata <= ven_dbg_w6;     // VEN DIAG: io_readdata @word6 spt (expect 0100)
		   12: mgmt_readdata <= ven_dbg_rdcnt;  // VEN DIAG: count of core data-port reads
		   13: mgmt_readdata <= ven_dbg_fm1;    // VEN DIAG2: io_readdata ~S_READ_W2 (should be 0040)
		   14: mgmt_readdata <= ven_dbg_f0;     // VEN DIAG2: io_readdata ~S_READ_CHK-1
		   // VEN FIX (Win95 disk-WRITE corruption): cases 15/16/17 REMOVED. mgmt_address is [3:0], so
		   // `15:` SHADOWED address 0xF — the BUFFER access address — and every ide_recvbuf word
		   // returned the ven_dbg_fp1 diag register (a constant, e.g. 0x0040/0x1c38) instead of the
		   // buffer: the guest's disk writes reached the file as ONE REPEATED WORD, overwriting the
		   // FAT root directory. (16/17 could never match a 4-bit address — dead code.) Address 0xF
		   // now falls to the default arm = the buffer word at mgmt_cnt, as the protocol requires.
	default: mgmt_readdata <= (mgmt_cnt[0]) ? buf_readdata[31:16] : buf_readdata[15:0];
	endcase
end

//------------------------------------------------------------------------------

reg [1:0] hob_ena = 0;
reg [1:0] present = 0;
always @(posedge clk) begin
	if(mgmt_write && mgmt_address == 6 && mgmt_writedata[3]) {hob_ena[0], present[0]} <= mgmt_writedata[1:0];
	if(mgmt_write && mgmt_address == 6 && mgmt_writedata[7]) {hob_ena[1], present[1]} <= mgmt_writedata[5:4];
end

reg use_wait = 0;
always @(posedge clk) begin
	if(mgmt_write && mgmt_address == 6 && mgmt_writedata[9]) use_wait <= mgmt_writedata[8];
end

//------------------------------------------------------------------------------

wire reset = ~rst_n | sw_reset;

reg disable_irq;
always @(posedge clk) begin
	if(reset)                          disable_irq <= 1'b0;
	else if(io_wr && io_address == 14) disable_irq <= io_writedata[1];
end

reg sw_reset;
assign dbg_disable_irq = disable_irq;   // bug#7 observers
assign dbg_sw_reset    = sw_reset;
always @(posedge clk) begin
	if(~rst_n)                         sw_reset <= 1'b0;
	else if(io_wr && io_address == 14) sw_reset <= io_writedata[2];
end

reg hob_pre;
always @(posedge clk) begin
	if(reset)                          hob_pre <= 1'b0;
	else if(io_wr && io_address == 14) hob_pre <= io_writedata[7];
end

reg hob;
always @(posedge clk) hob <= hob_pre & hob_ena[drv_addr[4]];

//------------------------------------------------------------------------------

wire write_data_io = io_wr   && io_address == 0 && drq;
wire read_data_io  = io_read && io_address == 0 && drq;

wire       io_done = (blk_size && io_cnt >= blk_size);
reg [13:0] io_cnt;
wire       io_stb = read_data_io | write_data_io;

// One completion record per daemon-published block.  The terminal decision is
// sampled exactly once at io_done, then the status/request consumers use that
// record on later clocks.  Do not consume the io_done level directly: mgmt
// word-5 publication and the last-read clear are independent sequential
// actions, so a level lets synthesis/order decide whether a terminal block is
// mistaken for a continuation.  Word 5 is the ownership handoff for the next
// block; it clears the old record and rearms the detector.
reg block_done_seen;
reg block_done_pending;
reg block_done_last;
reg [7:0] block_done_status;
always @(posedge clk) begin
	if(reset) begin
		block_done_seen    <= 1'b0;
		block_done_pending <= 1'b0;
		block_done_last    <= 1'b0;
		block_done_status  <= 8'h00;
	end
	else if(mgmt_write && mgmt_address == 5) begin
		block_done_seen    <= 1'b0;
		block_done_pending <= 1'b0;
	end
	// A new command supersedes a completed descriptor even before the daemon
	// publishes its next word-5 descriptor.  Keep `seen` set: io_done still
	// belongs to the old buffer and must not be consumed a second time.
	else if(io_wr && io_address == 7) begin
		block_done_pending <= 1'b0;
	end
	else if(io_done & drq & ~block_done_seen) begin
		block_done_seen    <= 1'b1;
		block_done_pending <= 1'b1;
		block_done_last    <= last_read;
		// The daemon's word-5 state is already latched in status.  Completion
		// changes only the data-ready ownership, so clear DRQ and retain DRDY,
		// DSC, ERR and the remaining ATA status bits as one immutable record.
		block_done_status  <= status & ~8'h08;
	end
	// `pending` is a one-clock dispatch record.  `seen` remains set until word
	// 5 ownership changes, preventing the held io_done level from replaying it.
	else if(block_done_pending) begin
		block_done_pending <= 1'b0;
	end
end

always @(posedge clk) begin
	reg old_stb, r_32;
	old_stb <= io_stb;

	if(io_stb) r_32 <= io_32;

	if(reset)                                io_cnt <= 0;
	else if(mgmt_write && mgmt_address == 5) io_cnt <= 0;
	else if(old_stb & ~io_stb)               io_cnt <= io_cnt + 1'd1 + r_32;
end

reg [13:0] mgmt_cnt;
always @(posedge clk) begin
	reg old_wr, old_rd;
	
	old_wr <= mgmt_write;
	old_rd <= mgmt_read;
	if((old_wr & ~mgmt_write) | (old_rd & ~mgmt_read)) begin
		if(&mgmt_address) mgmt_cnt <= mgmt_cnt + 1'd1;
		else mgmt_cnt <= 0;
	end
	
	if(~rst_n) mgmt_cnt <= 0;
end

wire       n_data = (mgmt_cnt[13:1] <= io_cnt[13:1]) && drq && fast_read;
reg  [1:0] n_data_r;
assign     no_data = n_data || n_data_r;
always @(posedge clk) n_data_r <= {n_data_r[0], n_data};

wire [31:0] buf_readdata;
wire [31:0] buf_q;

dpram #(12,16) io_buf0
(
	.clock(clk),

	.address_a(mgmt_cnt[12:1]),
	.data_a(mgmt_writedata),
	.wren_a(mgmt_write & &mgmt_address & ~mgmt_cnt[0]),
	.q_a(buf_readdata[15:0]),

	.address_b(io_cnt[12:1]),
	.data_b(io_writedata[15:0]),
	.wren_b(write_data_io & (io_32 | ~io_cnt[0])),
	.q_b(buf_q[15:0])
);

dpram #(12,16) io_buf1
(
	.clock(clk),

	.address_a(mgmt_cnt[12:1]),
	.data_a(mgmt_writedata),
	.wren_a(mgmt_write & &mgmt_address & mgmt_cnt[0]),
	.q_a(buf_readdata[31:16]),

	.address_b(io_cnt[12:1]),
	.data_b(io_32 ? io_writedata[31:16] : io_writedata[15:0]),
	.wren_b(write_data_io & (io_32 | io_cnt[0])),
	.q_b(buf_q[31:16])
);

//------------------------------------------------------------------------------
// VEN DIAG: observe the CORE's IDE data-port reads on real hardware. read_data_io is
// the core's data-FIFO read strobe; io_readdata is what the iobus latches for the core;
// buf_q is the raw dpram port-B output. If rdcnt advances but iord==0 while bufq!=0 the
// io_readdata mux (drq gate) is dropping it; if bufq==0 too the BRAM port-B read is dead.
// Capture the io_readdata the core takes at SPECIFIC word indices (0,1,3,6 = the identify
// geometry words config/cyl/heads/spt), so a zero vs a shift vs the correct value is visible.
reg [15:0] ven_dbg_w0 = 0, ven_dbg_w1 = 0, ven_dbg_w3 = 0, ven_dbg_w6 = 0, ven_dbg_rdcnt = 0;
reg        ven_dbg_rd_d = 0;
always @(posedge clk) begin
	ven_dbg_rd_d <= read_data_io;
	if (reset) ven_dbg_rdcnt <= 0;
	else begin
		if (read_data_io) case (io_cnt)
			14'd0: ven_dbg_w0 <= io_readdata[15:0];
			14'd1: ven_dbg_w1 <= io_readdata[15:0];
			14'd3: ven_dbg_w3 <= io_readdata[15:0];
			14'd6: ven_dbg_w6 <= io_readdata[15:0];
			default: ;
		endcase
		if (read_data_io & ~ven_dbg_rd_d) ven_dbg_rdcnt <= ven_dbg_rdcnt + 1'b1;
	end
end

// VEN DIAG 2: what does the CORE actually RECEIVE? The write-beat ring proved the core
// STORES zero from the identify -> io_rdata=0 at the core even though io_readdata (above)
// reads correct DURING read_data_io. The iobus latches io_readdata into cpu_read_data at
// S_READ_CHK (the cycle read_data_io deasserts). Capture io_readdata across THREE phases
// around that falling edge for the FIRST data read, so the valid window vs the latch cycle
// is visible: fall-1 (~S_READ_W2), fall (~S_READ_CHK), fall+1. Plus the raw buf_q & drq so
// a dead port-B vs a mis-timed latch vs a drq-gate drop are distinguishable.
reg [15:0] ven_dbg_iord_d1 = 0, ven_dbg_iord_d2 = 0;
reg [15:0] ven_dbg_fm1 = 0, ven_dbg_f0 = 0, ven_dbg_fp1 = 0;
reg [15:0] ven_dbg_bufq0 = 0;
reg [3:0]  ven_dbg_flags = 0;
reg [13:0] ven_dbg_fn = 0;
always @(posedge clk) begin
	ven_dbg_iord_d1 <= io_readdata[15:0];
	ven_dbg_iord_d2 <= ven_dbg_iord_d1;
	if (reset) ven_dbg_fn <= 0;
	else if (ven_dbg_rd_d & ~read_data_io) begin   // read_data_io just fell = iobus S_READ_CHK region
		if (ven_dbg_fn == 14'd0) begin
			ven_dbg_fm1   <= ven_dbg_iord_d2;      // ~S_READ_W2 (my ven_dbg_w0 capture point)
			ven_dbg_f0    <= ven_dbg_iord_d1;      // ~S_READ_CHK-1
			ven_dbg_fp1   <= io_readdata[15:0];    // ~S_READ_CHK / latch cycle
			ven_dbg_bufq0 <= buf_q[15:0];          // raw dpram port-B at the latch
			ven_dbg_flags <= {io_address[2:0], status[3]};   // drq + io_address at the latch
		end
		ven_dbg_fn <= ven_dbg_fn + 1'b1;
	end
end

endmodule
