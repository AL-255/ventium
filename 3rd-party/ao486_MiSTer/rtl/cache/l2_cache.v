`default_nettype wire  // added for Vivado project-flow synth (leak-proof; Quartus-style expects wire)

module l2_cache #(parameter ADDRBITS = 24, parameter CACHE_SETS = 128)
(
	input         CLK,
	input         RESET,

	input         DISABLE,

	// FPU co-sim cache-line invalidation:
	// pulse l2_inv_pulse high for one cycle to mark all ways of the set
	// selected by l2_inv_addr's line-index bits as needing-refetch.
	// l2_inv_addr is in the same units as read_addr (64-bit-beat address = byte_addr>>3).
	input         l2_inv_pulse,
	input [ADDRBITS:0] l2_inv_addr,

	// CPU bus, master, 32bit
	input  [29:0] CPU_ADDR,
	input  [31:0] CPU_DIN,
	output [31:0] CPU_DOUT,
	output        CPU_DOUT_READY,
	input   [3:0] CPU_BE,
	input   [3:0] CPU_BURSTCNT,
	output        CPU_BUSY,
	input         CPU_RD,
	input         CPU_WE,

	// DDR3 RAM, slave, 64bit
	output [ADDRBITS:0] DDRAM_ADDR,
	output [63:0] DDRAM_DIN,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output  [7:0] DDRAM_BE,
	output  [7:0] DDRAM_BURSTCNT,
	input         DDRAM_BUSY,
	output        DDRAM_RD,
	output        DDRAM_WE,

	// VGA bus, slave, 8bit
	output [16:0] VGA_ADDR,
	input   [7:0] VGA_DIN,
	output  [7:0] VGA_DOUT,
	input   [2:0] VGA_MODE,
	output        VGA_RD,
	output        VGA_WE,
`ifdef VEN_VGA_WIDE_STORE
	input         VGA_WIDE_READY,
	output        VGA_WIDE_WE,
	output [31:0] VGA_WIDE_DOUT,
`endif

	input   [5:0] VGA_WR_SEG,
	input   [5:0] VGA_RD_SEG,
	input         VGA_FB_EN,

	input         uma_ram
);


// cache settings
// Keep the four-way / 64-byte-line platform cache and its RAM ports.
// Only the per-way RAM depth changes; the core P5 L1s are untouched.
localparam LINES         = CACHE_SETS;
initial begin
    if ((CACHE_SETS < 128) || (CACHE_SETS > 1024) ||
        ((CACHE_SETS & (CACHE_SETS - 1)) != 0))
        $fatal(1, "platform L2 requires 128/256/512/1024 power-of-two sets");
end
localparam LINESIZE      = 8;
localparam ASSOCIATIVITY = 4;	

// cache control
localparam ASSO_BITS     = $clog2(ASSOCIATIVITY);
localparam LINESIZE_BITS = $clog2(LINESIZE);
localparam LINE_BITS     = $clog2(LINES);
localparam RAMSIZEBITS   = $clog2(LINESIZE * LINES);

localparam LINEMASKLSB   = $clog2(LINESIZE);
localparam LINEMASKMSB   = LINEMASKLSB + $clog2(LINES) - 1;

reg    [ASSOCIATIVITY-1:0]      tags_dirty_in;
reg    [ASSOCIATIVITY-1:0]      tags_dirty_out;
wire   [ADDRBITS-RAMSIZEBITS:0] tags_read[0:ASSOCIATIVITY-1];
reg                             update_tag_we;
reg    [LINE_BITS-1:0]          update_tag_addr;

// REVIEW2 H-20: the old comment said "Harness only pulses when the CPU bus is idle,
// so the two never collide in practice" -- and the interface does not enforce that.
// The actual co-sim generates the pulse immediately after FPU store processing
// (ao486-sim/sim_main.cpp) with NO L2-idle handshake, so a collision with
// update_tag_we silently DROPPED the invalidation and left stale data valid. Test-
// harness scheduling is not a coherence protocol.
//
// One-deep skid: an invalidation that collides is HELD and applied on the next cycle
// the state machine is not writing tags. Invalidation pulses are rare relative to tag
// writes, so one entry is sufficient; a second collision while one is pending is
// reported in simulation rather than silently dropped (see below).
// REVIEW1_Aug2 H-09: the one-entry skid above LOST invalidations two distinct ways,
// and a $display is not a fix:
//
//   1. a second colliding pulse OVERWROTE l2_inv_pend_addr -- the older set was
//      never invalidated;
//   2. worse and quieter: with the port free and one already pending, the mux picked
//      the FRESH address (l2_inv_pulse ? ...) while the sequential block took its
//      `else if (l2_inv_pend && !update_tag_we)` arm and cleared l2_inv_pend. The
//      pending set was retired WITHOUT ever being applied. No warning covered this one.
//
// The review's point is that a 1-deep overwriteable skid cannot be lossless for
// unconstrained pulses, and there is no ready/credit signal to constrain them.
//
// FIX: a pending BITMAP, one bit per set. This works because invalidation here is
// IDEMPOTENT and SET-INDEXED -- it just forces the dirty bits of every way in one set
// -- so two invalidations of the same set collapse to one with no loss of meaning, and
// The pending bitmap remains one bit per set, sized by LINES. Larger
// configurations require separate physical qualification of this encoder.
//
// It is lossless for ANY pulse rate without a producer contract: every pulse either
// applies in the same cycle or sets a bit, and a bit is only ever cleared by being
// applied. Backpressure is unnecessary; pulses arriving faster than free tag-write
// cycles are DELAYED, never dropped, which is the semantic the old code broke.
reg    [LINES-1:0]              l2_inv_pend_set;
wire   [LINE_BITS-1:0]          l2_inv_addr_idx = l2_inv_addr[LINEMASKMSB:LINEMASKLSB];
wire                            l2_inv_any = |l2_inv_pend_set;

// lowest pending set index (LINES-wide priority encoder)
reg    [LINE_BITS-1:0]          l2_inv_drain_idx;
integer                         l2_inv_i;
always @* begin
	l2_inv_drain_idx = {LINE_BITS{1'b0}};
	for (l2_inv_i = LINES-1; l2_inv_i >= 0; l2_inv_i = l2_inv_i - 1)
		if (l2_inv_pend_set[l2_inv_i]) l2_inv_drain_idx = l2_inv_i[LINE_BITS-1:0];
end

// A fresh pulse takes the port directly only when nothing is queued -- otherwise the
// QUEUE drains first, so invalidations cannot be starved by a steady pulse stream
// (which is how loss case 2 hid: the fresh one always won the mux).
wire                            l2_inv_apply_fresh = !update_tag_we && l2_inv_pulse && !l2_inv_any;
wire                            l2_inv_apply_pend  = !update_tag_we && l2_inv_any;

always @(posedge CLK) begin
	if (RESET) begin
		l2_inv_pend_set <= {LINES{1'b0}};
	end else begin
		// drain first, then enqueue: if both target the SAME set in one cycle the
		// enqueue wins (last NBA), so the invalidation is retried rather than lost.
		// A redundant re-invalidation is harmless; a dropped one is not.
		if (l2_inv_apply_pend)                    l2_inv_pend_set[l2_inv_drain_idx] <= 1'b0;
		if (l2_inv_pulse && !l2_inv_apply_fresh)  l2_inv_pend_set[l2_inv_addr_idx]  <= 1'b1;
	end
end

// An invalidation happens this cycle if a fresh pulse takes a free port, or a queued
// one is drained.
wire                            l2_inv_go   = l2_inv_apply_fresh || l2_inv_apply_pend;
wire   [LINE_BITS-1:0]          l2_inv_go_a = l2_inv_apply_fresh ? l2_inv_addr_idx
                                                                 : l2_inv_drain_idx;

// dirtyram write-port mux: state-machine tag write still has the port; an invalidation
// that loses now WAITS instead of vanishing.
wire   [ASSOCIATIVITY-1:0]      dirtyram_data   = update_tag_we ? tags_dirty_in : (l2_inv_go ? {ASSOCIATIVITY{1'b1}} : tags_dirty_in);
wire   [LINE_BITS-1:0]          dirtyram_wraddr = update_tag_we ? update_tag_addr : l2_inv_go_a;
wire                            dirtyram_wren   = update_tag_we | l2_inv_go;

reg    [ASSO_BITS-1:0] LRU_in [0:ASSOCIATIVITY-1];
reg    [ASSO_BITS-1:0] LRU_out[0:ASSOCIATIVITY-1];
reg                             LRU_we;
reg    [LINE_BITS-1:0]          LRU_addr;
// Keep the registered rank data and its write set together.
// A new request may change the read set before this write lands.
reg    [LINE_BITS-1:0]          LRU_wraddr;
wire [ASSO_BITS-1:0] LRU_rank[0:ASSOCIATIVITY-1];
wire LRU_write_through = LRU_we && (LRU_wraddr == LRU_addr);
genvar lru_rank_way;
generate for (lru_rank_way = 0; lru_rank_way < ASSOCIATIVITY; lru_rank_way = lru_rank_way + 1) begin
    assign LRU_rank[lru_rank_way] = LRU_write_through ? LRU_in[lru_rank_way] : LRU_out[lru_rank_way];
end endgenerate

localparam [3:0]
   START         = 0,
	IDLE          = 1,
	WRITEONE      = 2,
	READONE       = 3,
	FILLCACHE     = 4,
	READCACHE_OUT = 5,
	VGAREAD       = 6,
	VGAWAIT       = 7,
	VGABYTECHECK  = 8,
	VGAWRITE      = 9
`ifdef VEN_L2_STREAM_CWF
	,SCWF_STREAM  = 10,
	 SCWF_DRAIN   = 11,
	 SCWF_COMMIT  = 12,
	 SCWF_DONE    = 13
`endif
`ifdef VEN_VGA_WIDE_STORE
	,VGAWIDE      = 14
`endif
	;

// memory
wire              [31:0] readdata_cache[0:ASSOCIATIVITY-1];
reg      [ASSO_BITS-1:0] cache_mux;

reg    [RAMSIZEBITS-1:0] memory_addr_b;
reg               [63:0] memory_datain;
reg  [0:ASSOCIATIVITY-1] memory_we;
reg                [7:0] memory_be;
reg  [LINESIZE_BITS-1:0] fillcount;

reg   [3:0] state;

reg  [ADDRBITS:0] read_addr;
reg         [3:0] burst_left;

reg         force_fetch;
reg         force_next;

reg         data64_high;

// internal mux
reg         ram_dout_ready;
reg   [7:0] ram_burstcnt;
reg [ADDRBITS:0] ram_addr;
reg         ram_rd;
reg  [63:0] ram_din;
reg   [7:0] ram_be;
reg         ram_we;

reg         shr_rgn_en;
reg         read_behind;

reg         vga_ram;
reg  [31:0] vga_data;
reg  [31:0] vga_data_r;
reg   [3:0] vga_be;
reg   [2:0] vga_bcnt;
reg   [1:0] vga_ba;
reg         vga_wr;
reg         vga_re;
reg  [14:0] vga_wa;
reg   [1:0] vga_mask;
reg   [1:0] vga_cmp;
reg  [31:0] vga_next_data;
reg   [3:0] vga_next_be;
reg         vgabusy;

reg  [29:0] CPU_ADDR_1;
reg  [31:0] CPU_DIN_1;
reg         CPU_WE_1;

reg         RESET_1;
reg         RESET_2;

`ifdef VEN_L2_STREAM_CWF
// Stream only the lower half of an aligned L1 burst.  The existing DDR request
// remains one incrementing eight-beat read, so it incurs no second command
// latency; its first four beats are precisely this request's eight dwords.
// The tag stays invalid until the same burst's upper half has landed.
reg                     scw_candidate;
reg [2:0]               scw_fill_count;
reg [3:0]               scw_rsp_count;
`ifdef VEN_L2_STREAM_ANY
// Extend the response window, not the cache geometry or the DDR burst. Every
// accepted request retains its offset/count until its ordered response drains.
reg [3:0]               scw_start_word, scw_rsp_limit;
reg [63:0]              scw_head_data [0:7];
wire [3:0]              scw_rsp_word = scw_start_word + scw_rsp_count;
wire [31:0]             scw_selected_data = scw_rsp_word[0] ?
                             scw_head_data[scw_rsp_word[3:1]][63:32] :
                             scw_head_data[scw_rsp_word[3:1]][31:0];
`else
reg [63:0]              scw_head_data [0:3];
wire [3:0]              scw_rsp_limit = 4'd8;
wire [3:0]              scw_rsp_word = scw_rsp_count;
wire [31:0]             scw_selected_data = scw_rsp_word[0] ?
                             scw_head_data[scw_rsp_word[2:1]][63:32] :
                             scw_head_data[scw_rsp_word[2:1]][31:0];
`endif
reg [31:0]              scw_rsp_data;
reg                     scw_rsp_valid;
reg [ASSO_BITS-1:0]     scw_way;
reg                     scw_poison;
reg                     scw_cache_hit_now;
reg [ASSOCIATIVITY-1:0] scw_tags_commit;
integer                 scw_i;

wire scw_inv_this_line = ((l2_inv_pulse &&
					   (l2_inv_addr_idx == read_addr[LINEMASKMSB:LINEMASKLSB])) ||
					  (l2_inv_go &&
					   (l2_inv_go_a == read_addr[LINEMASKMSB:LINEMASKLSB])));

always @* begin
	scw_cache_hit_now = 1'b0;
	for (scw_i = 0; scw_i < ASSOCIATIVITY; scw_i = scw_i + 1)
		if (~tags_dirty_out[scw_i] &&
		    (tags_read[scw_i] == read_addr[ADDRBITS:RAMSIZEBITS]))
			scw_cache_hit_now = 1'b1;
end

always @* begin
	scw_tags_commit = tags_dirty_out;
	scw_tags_commit[scw_way] = 1'b0;
	if (scw_poison || scw_inv_this_line)
		scw_tags_commit = {ASSOCIATIVITY{1'b1}};
end

wire scw_fill_busy = (state == SCWF_STREAM) || (state == SCWF_DRAIN) ||
					 (state == SCWF_COMMIT) || (state == SCWF_DONE);
`endif

`ifndef SYNTHESIS
`ifdef VEN_L2_PERF
// Full-system performance attribution only.  The L1 presents both ordinary
// incrementing line reads and the two fragments of an AXI WRAP8 read through
// this legacy Avalon port.  Count the accepted shape at the consumer, rather
// than guessing it from AXI addresses elsewhere, before changing the L2 fill
// response policy.  These signals have no synthesis fanout.
reg [63:0] l2p_read, l2p_read_aligned8, l2p_lookup_hit, l2p_lookup_miss;
reg [63:0] l2p_miss_aligned8, l2p_fill_cycles, l2p_fill_beats;
reg [63:0] l2p_stream_cycles, l2p_stream_beats;
reg [63:0] l2p_read_burst [0:15], l2p_miss_burst [0:15];
reg [63:0] l2p_miss_start64 [0:7];
reg        l2p_tag_hit_now;
integer    l2p_i;

always @* begin
	l2p_tag_hit_now = 1'b0;
	for (l2p_i = 0; l2p_i < ASSOCIATIVITY; l2p_i = l2p_i + 1)
		if (~tags_dirty_out[l2p_i] &&
		    (tags_read[l2p_i] == read_addr[ADDRBITS:RAMSIZEBITS]))
			l2p_tag_hit_now = 1'b1;
end

always @(posedge CLK) begin
	if (RESET) begin
		l2p_read          <= 64'd0;
		l2p_read_aligned8 <= 64'd0;
		l2p_lookup_hit    <= 64'd0;
		l2p_lookup_miss   <= 64'd0;
		l2p_miss_aligned8 <= 64'd0;
		l2p_fill_cycles   <= 64'd0;
		l2p_fill_beats    <= 64'd0;
		l2p_stream_cycles <= 64'd0;
		l2p_stream_beats  <= 64'd0;
		for (l2p_i = 0; l2p_i < 16; l2p_i = l2p_i + 1) begin
			l2p_read_burst[l2p_i] <= 64'd0;
			l2p_miss_burst[l2p_i] <= 64'd0;
		end
		for (l2p_i = 0; l2p_i < 8; l2p_i = l2p_i + 1)
			l2p_miss_start64[l2p_i] <= 64'd0;
	end else begin
		if ((state == IDLE) && !DDRAM_BUSY && CPU_RD) begin
			l2p_read <= l2p_read + 64'd1;
			l2p_read_burst[CPU_BURSTCNT] <= l2p_read_burst[CPU_BURSTCNT] + 64'd1;
			// A full, 32-byte-aligned request is the only shape the L2 can
			// stream without recognizing a subsequent WRAP continuation.
			if ((CPU_BURSTCNT == 4'd8) && (CPU_ADDR[2:0] == 3'd0))
				l2p_read_aligned8 <= l2p_read_aligned8 + 64'd1;
		end
		if ((state == READONE) && !force_next) begin
			if (l2p_tag_hit_now) l2p_lookup_hit  <= l2p_lookup_hit + 64'd1;
			else begin
				l2p_lookup_miss <= l2p_lookup_miss + 64'd1;
				l2p_miss_burst[burst_left] <= l2p_miss_burst[burst_left] + 64'd1;
				l2p_miss_start64[read_addr[2:0]] <=
					l2p_miss_start64[read_addr[2:0]] + 64'd1;
				if ((burst_left == 4'd8) && (read_addr[1:0] == 2'd0))
					l2p_miss_aligned8 <= l2p_miss_aligned8 + 64'd1;
			end
		end
		if (state == FILLCACHE) begin
			l2p_fill_cycles <= l2p_fill_cycles + 64'd1;
			if (DDRAM_DOUT_READY) l2p_fill_beats <= l2p_fill_beats + 64'd1;
		end
`ifdef VEN_L2_STREAM_CWF
		// Keep legacy FILLCACHE accounting separate.  Streaming occupancy
		// includes response drain/publication, but DDR is consumed only in STREAM.
		if (scw_fill_busy) l2p_stream_cycles <= l2p_stream_cycles + 64'd1;
		if ((state == SCWF_STREAM) && DDRAM_DOUT_READY)
			l2p_stream_beats <= l2p_stream_beats + 64'd1;
`endif
	end
end

final begin
	$display("[L2PERF] cpu-read=%0d aligned-8=%0d lookup-hit=%0d lookup-miss=%0d miss-aligned-8=%0d",
		l2p_read, l2p_read_aligned8, l2p_lookup_hit, l2p_lookup_miss,
		l2p_miss_aligned8);
	$display("[L2PERF] fill-cycles=%0d fill-ddr-beats=%0d", l2p_fill_cycles, l2p_fill_beats);
	$display("[L2PERF] stream-cycles=%0d stream-ddr-beats=%0d total-fill-cycles=%0d total-fill-ddr-beats=%0d",
		l2p_stream_cycles, l2p_stream_beats,
		l2p_fill_cycles + l2p_stream_cycles, l2p_fill_beats + l2p_stream_beats);
	for (l2p_i = 0; l2p_i < 16; l2p_i = l2p_i + 1)
		if (l2p_read_burst[l2p_i] != 0)
			$display("[L2PERF] cpu-read-burst=%0d count=%0d", l2p_i, l2p_read_burst[l2p_i]);
	for (l2p_i = 0; l2p_i < 16; l2p_i = l2p_i + 1)
		if (l2p_miss_burst[l2p_i] != 0)
			$display("[L2PERF] miss-burst=%0d count=%0d", l2p_i, l2p_miss_burst[l2p_i]);
	for (l2p_i = 0; l2p_i < 8; l2p_i = l2p_i + 1)
		if (l2p_miss_start64[l2p_i] != 0)
			$display("[L2PERF] miss-start-64b=%0d count=%0d", l2p_i, l2p_miss_start64[l2p_i]);
end
`endif
`endif

assign DDRAM_BURSTCNT = ram_burstcnt;
assign DDRAM_ADDR     = ram_addr;
assign DDRAM_RD       = ram_rd;
assign DDRAM_DIN      = ram_din;
assign DDRAM_BE       = ram_be;
assign DDRAM_WE       = ram_we;

`ifdef VEN_L2_STREAM_CWF
// The streamed data is a response bypass, not an early cache hit.  Keep the
// request port busy through tail fill and tag publication so no following
// transaction can observe an incompletely installed line.
// START cannot consume a CPU command. Its duration depends on cache depth;
// callers must use BUSY, not an assumed reset delay. Keep both reset pipeline
// stages and the complete tag walk behind the same ordinary request handshake.
assign CPU_BUSY       = (RESET || RESET_1 || (state == START)) ? 1'b1 :
                        (state == IDLE) ? DDRAM_BUSY :
                        (vgabusy | ram_we | scw_fill_busy);
assign CPU_DOUT       = scw_rsp_valid ? scw_rsp_data :
                        (vga_ram ? vga_data_r : readdata_cache[cache_mux]);
`else
// START cannot consume a CPU command. Its duration depends on cache depth;
// callers must use BUSY, not an assumed reset delay. Keep both reset pipeline
// stages and the complete tag walk behind the same ordinary request handshake.
assign CPU_BUSY       = (RESET || RESET_1 || (state == START)) ? 1'b1 :
                        (state == IDLE) ? DDRAM_BUSY : (vgabusy | ram_we);
assign CPU_DOUT       = vga_ram ? vga_data_r : readdata_cache[cache_mux];
`endif
assign CPU_DOUT_READY = ram_dout_ready;

assign VGA_DOUT       = vga_data[7:0];
assign VGA_WE         = vga_wr & vga_be[0];
assign VGA_RD         = vga_re & vga_be[0];
assign VGA_ADDR       = {vga_wa, vga_ba};
`ifdef VEN_VGA_WIDE_STORE
// The VGA planes accept four distinct bytes together only in the qualified
// chain-4 mode. Recheck eligibility on the commit edge; a configuration change
// after acceptance falls back to the original byte sequencer.
assign VGA_WIDE_WE    = (state == VGAWIDE) && VGA_WIDE_READY &&
                        !(RESET_1 && !RESET_2);
assign VGA_WIDE_DOUT  = vga_next_data;
`endif

always @(posedge CLK) begin
	case (VGA_MODE)
		3'b100:		// 128K
			begin
				vga_mask <= 2'b00;
				vga_cmp  <= 2'b00;
			end
		
		3'b101:		// lower 64K
			begin
				vga_mask <= 2'b10;
				vga_cmp  <= 2'b00;
			end
		
		3'b110:		// 3rd 32K
			begin
				vga_mask <= 2'b11;
				vga_cmp  <= 2'b10;
			end
		
		3'b111:		// top 32K
			begin
				vga_mask <= 2'b11;
				vga_cmp  <= 2'b11;
			end
		
		default :	// disable VGA RAM
			begin
				vga_mask <= 2'b00;
				vga_cmp  <= 2'b11;
			end
	endcase
end

wire ram_rgn = !CPU_ADDR[29:ADDRBITS+2];                                                       // = below 256MB
wire rom_rgn = uma_ram ? (CPU_ADDR[ADDRBITS+1:14] == 'hC) || (CPU_ADDR[ADDRBITS+1:14] == 'hF)  // = 0xC0000-0xCFFFF (VGA-ROM), 0xD0000-0xEFFFF (UMA RAM), 0xF0000-0xFFFFF (BIOS-ROM)
                       : (CPU_ADDR[ADDRBITS+1:16] == 'h3);                                     // = 0xC0000-0xFFFFF (VGA-ROM...BIOS-ROM) (UMA RAM disabled)
wire vga_rgn = (CPU_ADDR[ADDRBITS+1:15] == 'h5)  && ((CPU_ADDR[14:13] & vga_mask) == vga_cmp); // = 0xA0000-0xBFFFF (VGA: exact region depends on VGA_MODE)
wire shr_rgn = (CPU_ADDR[ADDRBITS+1:11] == 'h67) && shr_rgn_en;                                // = 0xCE000-0xCFFFF (used by shared folder)

wire [7:0] be64 = CPU_ADDR[0] ? {CPU_BE, 4'h0} : {4'h0, CPU_BE};

always @(posedge CLK) begin
	reg [ASSO_BITS:0] i;
	reg [ASSO_BITS-1:0] match;
	
	ram_dout_ready <= 1'b0;
	memory_we      <= {ASSOCIATIVITY{1'b0}};
	
	RESET_1 <= RESET;
	RESET_2 <= RESET_1;

	if (RESET_1 && ~RESET_2) begin
		state           <= START;
		update_tag_addr <= {LINE_BITS{1'b0}};
		update_tag_we   <= 1'b1;
		tags_dirty_in   <= {ASSOCIATIVITY{1'b1}};
		shr_rgn_en      <= 1'b0;
		vgabusy         <= 1'b0;
		// The VGA RAM write port is not reset-gated downstream.  Quiesce
		// these registered strobes before START walks the tag RAM again.
		vga_wr          <= 1'b0;
		vga_re          <= 1'b0;
		vga_be          <= 4'b0000;
`ifdef VEN_L2_STREAM_CWF
		scw_candidate   <= 1'b0;
		scw_fill_count  <= 3'd0;
		scw_rsp_count   <= 4'd0;
`ifdef VEN_L2_STREAM_ANY
		scw_start_word  <= 4'd0;
		scw_rsp_limit   <= 4'd0;
`endif
		scw_rsp_data    <= 32'd0;
		scw_rsp_valid   <= 1'b0;
		scw_way         <= {ASSO_BITS{1'b0}};
		scw_poison      <= 1'b0;
`endif
	end
	else begin
	`ifdef VEN_L2_STREAM_CWF
		// This defaults low every cycle.  A response is intentionally a
		// one-cycle valid pulse, exactly like the normal cache-read path.
		scw_rsp_valid <= 1'b0;
	`endif
		
		if (~DDRAM_BUSY) begin
			ram_rd <= 1'b0;
			ram_we <= 1'b0;
		end

		// LRU update after read
		LRU_wraddr <= LRU_addr;
		LRU_we <= ram_dout_ready && ~LRU_we;
		for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
			LRU_in[i] <= LRU_rank[i];
			if (cache_mux == i[ASSO_BITS-1:0]) begin
				match     = LRU_rank[i];
				LRU_in[i] <= {ASSO_BITS{1'b0}};
			end
		end
		for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
			if (LRU_rank[i] < match) begin
				LRU_in[i] <= LRU_rank[i] + 1'd1;
			end
		end

		if (CPU_WE_1 && (CPU_ADDR_1 == 'h33800) && (CPU_DIN_1[15:0] == 'hA345)) shr_rgn_en <= 1'b1;
		
		case (state)
			
			START:
				begin
					update_tag_addr <= update_tag_addr + 1'd1;

					for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
						LRU_in[i]    <= i[ASSO_BITS-1:0]; 
					end
					LRU_addr        <= update_tag_addr;
					LRU_wraddr      <= update_tag_addr;
					LRU_we          <= 1'b1; 

					if (update_tag_addr == {LINE_BITS{1'b1}}) begin
						state         <= IDLE;
						update_tag_we <= 1'b0;
					end
				end

			IDLE:
				begin
					vga_wr <= 1'b0;
					vga_re <= 1'b0;
					if (!DDRAM_BUSY) begin
						
						// for timing purposes, most registers are assigned without region checks
						CPU_ADDR_1    <= CPU_ADDR;
						CPU_DIN_1     <= CPU_DIN;
						CPU_WE_1      <= CPU_WE;

						ram_addr      <= CPU_ADDR[ADDRBITS+1:1];
						ram_burstcnt  <= 8'h01;
						read_addr     <= CPU_ADDR[ADDRBITS+1:1];
                        // READONE may irrevocably select a streaming victim.
                        // Put THIS request's set on the existing asynchronous
                        // LRU RAM read port at admission, alongside read_addr.
                        // Waiting until READONE selects from the previous set.
                        LRU_addr <= CPU_ADDR[LINEMASKMSB+1:LINEMASKLSB+1];
						burst_left    <= CPU_BURSTCNT;
						data64_high   <= CPU_ADDR[0];

						vga_wa        <= CPU_ADDR[14:0];
						vga_bcnt      <= 3;
						vga_next_data <= CPU_DIN;
						vga_next_be   <= CPU_BE;
						vga_ba        <= 2'b00;
						vga_be        <= CPU_BE;

						ram_din       <= {CPU_DIN, CPU_DIN};
						ram_be        <= be64;

						memory_datain <= {CPU_DIN, CPU_DIN};
						memory_be     <= be64;
						memory_addr_b <= CPU_ADDR[RAMSIZEBITS:1];

						read_behind   <= ~ram_rgn;
						force_fetch   <= shr_rgn | DISABLE;
						force_next    <= shr_rgn | DISABLE;
	`ifdef VEN_L2_STREAM_CWF
						// L1 presents an eight-dword, 32-byte request.  Bit 3 selects
						// the half of L2's 64-byte line: only the lower half arrives in
						// the first four beats of its normal incrementing DDR fill.
`ifdef VEN_L2_STREAM_ANY
						// Avalon addresses are dwords. Never cross this 64-byte
						// allocation, and never extend a device/shadow access.
						scw_candidate <= CPU_RD && (CPU_BURSTCNT != 4'd0) &&
						                 (CPU_BURSTCNT <= 4'd8) &&
						                 ({1'b0, CPU_ADDR[3:0]} + {1'b0, CPU_BURSTCNT} <= 5'd16) &&
						                 ram_rgn && !vga_rgn && !shr_rgn && !DISABLE;
`else
						scw_candidate <= CPU_RD && (CPU_BURSTCNT == 4'd8) &&
						                 (CPU_ADDR[3:0] == 4'd0) && ram_rgn &&
						                 !vga_rgn && !shr_rgn && !DISABLE;
`endif
	`endif

						if (CPU_RD) begin
							state     <= READONE;
							if (vga_rgn & ram_rgn) begin
								if(VGA_FB_EN) begin
									ram_addr[24:13]  <= {6'b111110, VGA_RD_SEG};
									read_addr[24:13] <= {6'b111110, VGA_RD_SEG};
								end
								else begin
									vga_re  <= 1'b1;
									state   <= VGAWAIT;
								end
							end
						end
						else if (CPU_WE & (~rom_rgn | shr_rgn) & ram_rgn) begin
							if (vga_rgn) begin
								if(VGA_FB_EN) begin
									ram_addr[24:13]  <= {6'b111110, VGA_WR_SEG};
									read_addr[24:13] <= {6'b111110, VGA_WR_SEG};
									ram_we  <= 1'b1;
									state   <= WRITEONE;
								end
								else begin
									vgabusy <= 1'b1;
	`ifdef VEN_VGA_WIDE_STORE
									if (CPU_BE == 4'b1111 && VGA_WIDE_READY)
										state <= VGAWIDE;
									else
	`endif
	`ifdef VEN_VGA_FULL_STORE_SETUP
									// Full-strobe VGA stores need no leading-byte search.
									// Start the SAME four byte transactions one cycle earlier;
									// VGAWRITE still owns byte order and final busy release.
									if (CPU_BE == 4'b1111) begin
										vga_data <= CPU_DIN;
										vga_wr   <= 1'b1;
										state    <= VGAWRITE;
										end
									else state <= VGABYTECHECK;
	`else
									state   <= VGABYTECHECK;
	`endif
								end
							end
							else begin
								ram_we  <= 1'b1;
								state   <= WRITEONE;
							end
						end
					end
				end
			
			WRITEONE:
				begin
					state <= IDLE;
					for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
						if (~tags_dirty_out[i]) begin
							if (tags_read[i] == read_addr[ADDRBITS:RAMSIZEBITS]) memory_we[i] <= 1'b1;
						end
					end
				end
			
			READONE:
				begin
`ifdef VEN_L2_STREAM_CWF
					// A candidate must still take the ordinary hit path.  Streaming
					// is exclusively a miss response optimisation; it never changes
					// cache-hit ordering or force-fetch semantics.
					if (scw_candidate && !force_next && !scw_cache_hit_now
`ifndef VEN_L2_STREAM_ANY
					    // The original lower-half path has a fixed eight-word
					    // response. A mid-burst invalidation must use the legacy
					    // remaining-word path instead of duplicating prior words.
					    && (burst_left == 4'd8)
`endif
					   ) begin
						vga_ram         <= 1'b0;
						vga_data_r      <= 32'd0;
						state           <= SCWF_STREAM;
						ram_rd          <= 1'b1;
						ram_addr        <= {read_addr[ADDRBITS:LINESIZE_BITS], {LINESIZE_BITS{1'b0}}};
						ram_be          <= 8'h00;
						ram_burstcnt    <= LINESIZE[7:0];
						memory_addr_b   <= {read_addr[RAMSIZEBITS - 1:LINESIZE_BITS], {LINESIZE_BITS{1'b0}}};
						tags_dirty_in   <= tags_dirty_out;
						update_tag_addr <= read_addr[LINEMASKMSB:LINEMASKLSB];
						update_tag_we   <= 1'b0;
						LRU_addr        <= read_addr[LINEMASKMSB:LINEMASKLSB];
						scw_fill_count  <= 3'd0;
						scw_rsp_count   <= 4'd0;
`ifdef VEN_L2_STREAM_ANY
						// The miss can follow an invalidated partial cache hit.
						// Capture the current cursor, never the original command.
						scw_start_word  <= {read_addr[2:0], data64_high};
						scw_rsp_limit   <= burst_left;
`endif
						scw_poison      <= scw_inv_this_line;
						for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
							if (LRU_rank[i] == {ASSO_BITS{1'b1}}) begin
								cache_mux <= i[ASSO_BITS-1:0];
								scw_way   <= i[ASSO_BITS-1:0];
							end
						end
					end
					else begin
`endif
					vga_ram         <= read_behind;		// use fake vga response for reading behind available ram
					vga_data_r      <= 32'd0;
					state           <= FILLCACHE;
					ram_rd          <= 1'b1;
					ram_addr        <= {read_addr[ADDRBITS:LINESIZE_BITS], {LINESIZE_BITS{1'b0}}};
					ram_be          <= 8'h00;
					ram_burstcnt    <= LINESIZE[7:0];
					fillcount       <= 0;
					memory_addr_b   <= {read_addr[RAMSIZEBITS - 1:LINESIZE_BITS], {LINESIZE_BITS{1'b0}}};
					tags_dirty_in   <= tags_dirty_out;
					update_tag_addr <= read_addr[LINEMASKMSB:LINEMASKLSB];
					update_tag_we   <= 1'b0;
					LRU_addr        <= read_addr[LINEMASKMSB:LINEMASKLSB];

					if (force_fetch) force_next <= ~force_next;

					if (~force_next) begin
						for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
							if (~tags_dirty_out[i]) begin
								if (tags_read[i] == read_addr[ADDRBITS:RAMSIZEBITS]) begin
									ram_rd         <= 1'b0;
									cache_mux      <= i[ASSO_BITS-1:0];
									ram_dout_ready <= 1'b1;
									if (burst_left > 1) begin
										state       <= READONE;
										burst_left  <= burst_left - 1'd1;
										data64_high <= ~data64_high;
										if (data64_high) read_addr <= read_addr + 1'd1;
									end
									else begin
										state <= IDLE;
									end
								end
							end
						end
					end
					else begin
						tags_dirty_in <= {ASSOCIATIVITY{1'b1}};
						update_tag_we <= 1'b1;
					end
`ifdef VEN_L2_STREAM_CWF
					end
`endif
				end
			
			FILLCACHE:
				begin
					for (i = 0; i < ASSOCIATIVITY; i = i + 1'd1) begin
						if (LRU_rank[i] == {ASSO_BITS{1'b1}} ) cache_mux <= i[ASSO_BITS-1:0]; 
					end

					if (DDRAM_DOUT_READY) begin
						memory_datain        <= DDRAM_DOUT;
						memory_we[cache_mux] <= 1'b1;
						memory_be            <= 8'hFF;

						tags_dirty_in[cache_mux] <= 1'b0;

						if (fillcount > 0) memory_addr_b <= memory_addr_b + 1'd1;
						if (fillcount < LINESIZE - 1) fillcount <= fillcount + 1'd1;
						else begin 
							state         <= READCACHE_OUT;
							update_tag_we <= 1'b1;
						end
					end
				end

`ifdef VEN_L2_STREAM_CWF
			// A lower-half fill has the requested words as DDR beats 0..3.
			// Store every beat exactly as the legacy fill does, but also retain
			// those first four beats in a tiny response FIFO.  The DDR command
			// is unchanged: one contiguous eight-beat line read.
			SCWF_STREAM:
				begin
					if (scw_inv_this_line) scw_poison <= 1'b1;

					if (DDRAM_DOUT_READY) begin
						memory_datain       <= DDRAM_DOUT;
						memory_we[scw_way]  <= 1'b1;
						memory_be           <= 8'hFF;
						if (scw_fill_count > 0) memory_addr_b <= memory_addr_b + 1'd1;
`ifdef VEN_L2_STREAM_ANY
						scw_head_data[scw_fill_count] <= DDRAM_DOUT;
`else
						if (scw_fill_count < 3'd4)
							scw_head_data[scw_fill_count[1:0]] <= DDRAM_DOUT;
`endif
						if (scw_fill_count < LINESIZE - 1) scw_fill_count <= scw_fill_count + 1'd1;
						else begin
							tags_dirty_in   <= scw_tags_commit;
							update_tag_we   <= 1'b1;
							// DDR may finish one cycle before the final
							// lower-half dword can be emitted.  Drain that
							// accepted burst before making the cache idle.
							state           <= SCWF_DRAIN;
						end
					end

					// A word becomes visible only after its containing DDR beat was
					// captured.  This remains independent of later tail beats.
					if ((scw_rsp_word < {scw_fill_count, 1'b0}) &&
						(scw_rsp_count < scw_rsp_limit)) begin
						scw_rsp_data  <= scw_selected_data;
						scw_rsp_valid <= 1'b1;
						ram_dout_ready <= 1'b1;
						scw_rsp_count <= scw_rsp_count + 1'd1;
					end
				end

			SCWF_DRAIN:
				begin
					if (scw_rsp_count < scw_rsp_limit) begin
						scw_rsp_data  <= scw_selected_data;
						scw_rsp_valid <= 1'b1;
						ram_dout_ready <= 1'b1;
						scw_rsp_count <= scw_rsp_count + 1'd1;
`ifdef VEN_L2_STREAM_ANY
						// The final response is registered on this edge. Commit
						// still keeps CPU_BUSY asserted on the next edge; do not
						// spend an extra drain cycle merely observing the count.
						if (scw_rsp_count + 4'd1 == scw_rsp_limit)
							state <= SCWF_COMMIT;
`endif
					end
					else begin
						state <= SCWF_COMMIT;
					end
				end

			// This cycle writes both tag RAMs, synchronized with the final RAM
			// data write scheduled above.  A fill-time invalidation poisons the
			// line instead of allowing a stale line to become valid.
			SCWF_COMMIT:
				begin
					update_tag_we <= 1'b0;
					state         <= SCWF_DONE;
				end

			SCWF_DONE:
				begin
					state         <= IDLE;
					scw_candidate <= 1'b0;
					scw_poison    <= 1'b0;
				end
`endif
			
			VGAWAIT:
				state <= VGAREAD;
			
			VGAREAD:
				begin
					vga_ram  <= 1'b1;
					vga_bcnt <= vga_bcnt - 1'd1;
					vga_be   <= {1'b0, vga_be[3:1]};
					vga_ba   <= vga_ba + 1'd1;
					vga_data <= {VGA_DIN, vga_data[31:8]};
					state    <= VGAWAIT;

					if (!vga_bcnt) begin
						ram_dout_ready <= 1'b1;
						vga_data_r     <= {VGA_DIN, vga_data[31:8]};
						if (burst_left > 1) begin
							vga_wa      <= vga_wa + 1'd1;
							vga_ba      <= 2'b00;
							vga_bcnt    <= 3;
							vga_be      <= 4'b1111;
							burst_left  <= burst_left - 1'd1;
						end
						else begin
							state <= IDLE;
						end
					end
				end
			
			VGABYTECHECK:
				begin
					state  <= VGAWRITE;
					vga_wr <= 1'b1;
					if (!vga_next_be[2:0]) begin
						vga_data <= {24'h000000, vga_next_data[31:24]};
						vga_be   <= {3'b000, vga_next_be[3]};
						vga_ba   <= 2'b11;
					end
					else if (!vga_next_be[1:0]) begin
						vga_data <= {16'h0000, vga_next_data[31:16]};
						vga_be   <= {2'b00, vga_next_be[3:2]};
						vga_ba   <= 2'b10;
					end
					else if (!vga_next_be[0]) begin
						vga_data <= {8'h00, vga_next_data[31:8]};
						vga_be   <= {1'b0, vga_next_be[3:1]};
						vga_ba   <= 2'b01;
					end
					else begin
						vga_data <= vga_next_data;
						vga_be   <= vga_next_be;
						vga_ba   <= 2'b00;
					end
				end

			VGAWRITE:
				begin
					vga_bcnt   <= vga_bcnt - 1'd1;
					vga_be     <= {1'b0, vga_be[3:1]};
					vga_ba     <= vga_ba + 1'd1;
					vga_data   <= {8'h00, vga_data[31:8]};
					if (!vga_be[3:1]) begin
						state   <= IDLE;
						vgabusy <= 1'b0;
					end
				end

`ifdef VEN_VGA_WIDE_STORE
			VGAWIDE:
				begin
					if (VGA_WIDE_READY) begin
						state   <= IDLE;
						vgabusy <= 1'b0;
					end
					else state <= VGABYTECHECK;
				end
`endif

			READCACHE_OUT:
				begin
					state         <= READONE;
					update_tag_we <= 1'b0;
				end
		endcase
	end
end

altdpram #(
	.indata_aclr("OFF"),
	.indata_reg("INCLOCK"),
	.intended_device_family("Cyclone V"),
	.lpm_type("altdpram"),
	.outdata_aclr("OFF"),
	.outdata_reg("UNREGISTERED"),
	.ram_block_type("MLAB"),
	.rdaddress_aclr("OFF"),
	.rdaddress_reg("UNREGISTERED"),
	.rdcontrol_aclr("OFF"),
	.rdcontrol_reg("UNREGISTERED"),
	.read_during_write_mode_mixed_ports("CONSTRAINED_DONT_CARE"),
	.width(ASSOCIATIVITY),
	.widthad(LINE_BITS),
	.width_byteena(1),
	.wraddress_aclr("OFF"),
	.wraddress_reg("INCLOCK"),
	.wrcontrol_aclr("OFF"),
	.wrcontrol_reg("INCLOCK")
)
dirtyram (
	.inclock(CLK),
	.outclock(CLK),

	.data(dirtyram_data),
	.rdaddress(read_addr[LINEMASKMSB:LINEMASKLSB]),
	.wraddress(dirtyram_wraddr),
	.wren(dirtyram_wren),
	.q(tags_dirty_out)
);

generate
	genvar i;
	for (i = 0; i < ASSOCIATIVITY; i = i + 1) begin : gcache
		altdpram #(
			.indata_aclr("OFF"),
			.indata_reg("INCLOCK"),
			.intended_device_family("Cyclone V"),
			.lpm_type("altdpram"),
			.outdata_aclr("OFF"),
			.outdata_reg("UNREGISTERED"),
			.ram_block_type("MLAB"),
			.rdaddress_aclr("OFF"),
			.rdaddress_reg("UNREGISTERED"),
			.rdcontrol_aclr("OFF"),
			.rdcontrol_reg("UNREGISTERED"),
			.read_during_write_mode_mixed_ports("CONSTRAINED_DONT_CARE"),
			.width(ADDRBITS - RAMSIZEBITS + 1),
			.widthad(LINE_BITS),
			.width_byteena(1),
			.wraddress_aclr("OFF"),
			.wraddress_reg("INCLOCK"),
			.wrcontrol_aclr("OFF"),
			.wrcontrol_reg("INCLOCK")
		)
		tagram (
			.inclock(CLK),
			.outclock(CLK),
			
			.data(read_addr[ADDRBITS:RAMSIZEBITS]),
			.rdaddress(read_addr[LINEMASKMSB:LINEMASKLSB]),
			.wraddress(read_addr[LINEMASKMSB:LINEMASKLSB]),
		.wren(((state == READCACHE_OUT)
`ifdef VEN_L2_STREAM_CWF
			 || (state == SCWF_COMMIT)
`endif
			) && (cache_mux == i)),
			.q(tags_read[i])
		);

		altdpram #(
			.indata_aclr("OFF"),
			.indata_reg("INCLOCK"),
			.intended_device_family("Cyclone V"),
			.lpm_type("altdpram"),
			.outdata_aclr("OFF"),
			.outdata_reg("UNREGISTERED"),
			.ram_block_type("MLAB"),
			.rdaddress_aclr("OFF"),
			.rdaddress_reg("UNREGISTERED"),
			.rdcontrol_aclr("OFF"),
			.rdcontrol_reg("UNREGISTERED"),
			.read_during_write_mode_mixed_ports("CONSTRAINED_DONT_CARE"),
			.width(ASSO_BITS),
			.widthad(LINE_BITS),
			.width_byteena(1),
			.wraddress_aclr("OFF"),
			.wraddress_reg("INCLOCK"),
			.wrcontrol_aclr("OFF"),
			.wrcontrol_reg("INCLOCK")
		)
		LRUram (
			.inclock(CLK),
			.outclock(CLK),
			
			.data(LRU_in[i]),
			.rdaddress(LRU_addr),
			.wraddress(LRU_wraddr),
			.wren(LRU_we),
			.q(LRU_out[i])
		);
		
		altsyncram #(
			.address_aclr_b("NONE"),
			.address_reg_b("CLOCK0"),
			.byte_size(8),
			.clock_enable_input_a("BYPASS"),
			.clock_enable_input_b("BYPASS"),
			.clock_enable_output_b("BYPASS"),
			.intended_device_family("Cyclone V"),
			.lpm_type("altsyncram"),
			.numwords_a(2**RAMSIZEBITS),
			.numwords_b(2**(RAMSIZEBITS+1)),
			.operation_mode("DUAL_PORT"),
			.outdata_aclr_b("NONE"),
			.outdata_reg_b("UNREGISTERED"),
			.power_up_uninitialized("FALSE"),
			.read_during_write_mode_mixed_ports("DONT_CARE"),
			.widthad_a(RAMSIZEBITS),
			.widthad_b(RAMSIZEBITS+1),
			.width_a(64),
			.width_b(32),
			.width_byteena_a(8)
		)
		ram (
			.clock0 (CLK),

			.address_a(memory_addr_b),
			.byteena_a(memory_be),
			.data_a(memory_datain),
			.wren_a(memory_we[i]),

			.address_b({read_addr[RAMSIZEBITS - 1:0], data64_high}),
			.q_b(readdata_cache[i]),

			.aclr0(1'b0),
			.aclr1(1'b0),
			.addressstall_a(1'b0),
			.addressstall_b(1'b0),
			.byteena_b(1'b1),
			.clock1(1'b1),
			.clocken0(1'b1),
			.clocken1(1'b1),
			.clocken2(1'b1),
			.clocken3(1'b1),
			.data_b(32'b0),
			.eccstatus(),
			.q_a(),
			.rden_a(1'b1),
			.rden_b(1'b1),
			.wren_b(1'b0)
		);
	end
endgenerate 

endmodule
