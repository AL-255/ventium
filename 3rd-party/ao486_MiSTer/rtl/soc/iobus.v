`default_nettype wire  // added for Vivado project-flow synth (leak-proof; Quartus-style expects wire)

module iobus
(
	input             clk,
	input             reset,

	input             cpu_read_do,
	input      [15:0] cpu_read_address,
	input      [2:0]  cpu_read_length,
	output reg [31:0] cpu_read_data,
	output reg        cpu_read_done,
	input             cpu_write_do,
	input      [15:0] cpu_write_address,
	input      [2:0]  cpu_write_length,
	input      [31:0] cpu_write_data,
	output reg        cpu_write_done,

	output reg [15:0] bus_address,
	output reg        bus_write,
	output reg        bus_read,
	input             bus_io32,
	output reg  [2:0] bus_datasize,
	output reg [31:0] bus_writedata,
	input      [31:0] bus_readdata,
	input             bus_wait
);

localparam S_IDLE      = 0;
localparam S_WRITE     = 1;
localparam S_WRITE_W   = 2;
localparam S_WRITE_CHK = 3;
localparam S_READ      = 4;
localparam S_READ_W    = 5;
localparam S_READ_CHK  = 6;
localparam S_READ_W2   = 7;   // extra read settle cycle: the io_readdata path (BRAM read +
                              // ide.v io_readdata register) needs one more clock than S_READ_W
                              // provides, else the core latches mem[io_cnt-1] (identify read
                              // came back shifted by one word on hardware -> zero geometry).
`ifdef VEN_SNOW_DBG
	integer ven_io_cnt = 0;
`endif

always @(posedge clk) begin
	reg [2:0] state;
	reg [1:0] cnt;

	cpu_read_done <= 0;
	cpu_write_done <= 0;
	bus_read <= 0;
	bus_write <= 0;

	case(state)
		S_IDLE:
			begin
				bus_address   <= cpu_write_do ? cpu_write_address : cpu_read_address;
				bus_datasize  <= cpu_write_do ? cpu_write_length  : cpu_read_length;
				bus_writedata <= cpu_write_data;
				cnt <= 0;

				if(cpu_read_do)  state <= S_READ;
				if(cpu_write_do) state <= S_WRITE;
			end

		S_WRITE:
			begin
				bus_write <= 1;
				state <= S_WRITE_W;
			end
			
		S_WRITE_W:
			begin
				state <= S_WRITE_CHK;
			end
		
		S_WRITE_CHK:
			if(~bus_wait) begin
				bus_address   <= bus_address + 1'd1;
				bus_writedata <= bus_writedata >> 8;
				bus_datasize  <= bus_datasize - 1'd1;
				state <= S_WRITE;
				if(bus_datasize == 1 || bus_io32) begin
					cpu_write_done <= 1;
					state <= S_IDLE;
				end
			end

		S_READ:
			begin
				bus_read <= 1;
				state <= S_READ_W;
			end

		S_READ_W:
			// REVIEW Aug-1 H-13: this used to re-assert `bus_read <= 1` here, which made
			// ONE logical I/O read drive the device read strobe for TWO clocks. Several
			// devices tolerate the level; the floppy does not -- it consumes io_read
			// directly to pop its reply FIFO and count down the reply (floppy.v:631
			// `reply_left <= reply_left - 1` and :657 `reply <= reply >> 8`, plus :233/:246
			// clearing transfer_to_cpu/busy and :465 clearing irq). A single guest FDC
			// data-port read therefore consumed TWO result bytes and could drop IRQ/busy
			// early. (Repro: IOBUS_READ_STROBE high_cycles=2.)
			//
			// The extra settle CYCLE it was added for is still needed and is still here:
			// S_READ_W2 delays S_READ_CHK's sample by one clock so the ide.v io_readdata
			// register (plus its BRAM read) has caught up. Holding the STROBE was never
			// what produced that delay. ide.v advances io_cnt on the strobe's FALLING edge
			// (`old_stb & ~io_stb`, ide.v:292), so a one-clock pulse still latches
			// io_readdata against the PRE-advance io_cnt -- which is the off-by-one-word
			// IDENTIFY behaviour the extra state was introduced to fix -- and the latched
			// value then stays stable through S_READ_W2/S_READ_CHK because the strobe is
			// low. So the IDE fix is preserved and the double-consume is gone.
			state <= S_READ_W2;

		S_READ_W2:
			state <= S_READ_CHK;

		S_READ_CHK:
			if(~bus_wait) begin
				bus_address <= bus_address + 1'd1;
				cnt <= cnt + 1'd1;
				bus_datasize <= bus_datasize - 1'd1;
				cpu_read_data[{cnt, 3'b000} +:8] <= bus_readdata[7:0];
`ifdef VEN_SNOW_DBG
				if(bus_address[7:0]==8'hDA || bus_address[7:0]==8'hBA) begin
					ven_io_cnt = ven_io_cnt + 1;
					if(ven_io_cnt<30 || ven_io_cnt%100000==0) $display("[IOBUS] addr=%h #%0d rdata=%02h b1=%b", bus_address, ven_io_cnt, bus_readdata[7:0], bus_readdata[1]);
				end
`endif
				state <= S_READ;

				if(bus_io32) cpu_read_data <= bus_readdata;

				if(bus_datasize == 1 || bus_io32) begin
					cpu_read_done <= 1;
					state <= S_IDLE;
				end
			end
	endcase
	
	if(reset) state <= S_IDLE;
end

endmodule
