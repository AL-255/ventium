`timescale 1ns/1ps
// Geometry-sensitive stores against real registered/read-first FPGA RAMs.
// Independent backing RAM and byte oracle; no DUT state writes or snapshots.
module tb_l2_capacity_stores;
  parameter integer SETS = 128;
  localparam integer BASE = 'h200000;
  localparam integer WORDS = SETS*6*16;
  reg CLK=0; always #5 CLK=~CLK;
  reg RESET=0, DISABLE=0, l2_inv_pulse=0;
  reg [24:0] l2_inv_addr=0;
  reg [29:0] CPU_ADDR=0;
  reg [31:0] CPU_DIN=0;
  wire [31:0] CPU_DOUT;
  wire CPU_DOUT_READY, CPU_BUSY;
  reg [3:0] CPU_BE=15, CPU_BURSTCNT=1;
  reg CPU_RD=0, CPU_WE=0;
  wire [24:0] DDRAM_ADDR;
  wire [63:0] DDRAM_DIN;
  reg [63:0] DDRAM_DOUT=0;
  reg DDRAM_DOUT_READY=0;
  wire [7:0] DDRAM_BE, DDRAM_BURSTCNT;
  wire DDRAM_RD, DDRAM_WE;
  wire [16:0] VGA_ADDR;
  reg [7:0] VGA_DIN=0;
  wire [7:0] VGA_DOUT;
  reg [2:0] VGA_MODE=0;
  wire VGA_RD,VGA_WE;
  reg [5:0] VGA_WR_SEG=0, VGA_RD_SEG=0;
  reg VGA_FB_EN=0, uma_ram=0;
  bit started=0, active=0;
  int stall_n=0, due=0, remaining=0, next_word=0;
  wire DDRAM_BUSY=active || stall_n!=0;
  l2_cache #(.ADDRBITS(24)
`ifdef L2_CAPACITY_PARAM
    ,.CACHE_SETS(SETS)
`endif
  ) dut (.*);
  reg [31:0] ram[0:WORDS-1], expected[0:WORDS-1];
  int cyc=0, writes=0, reads=0, mutations=0, ddr_reads=0;
  int cadence=1;
  reg held=0;
  reg [107:0] held_command;
  wire [107:0] ddr_command={DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_BURSTCNT,DDRAM_RD,DDRAM_WE,1'b0};
  always @(posedge CLK) begin
    cyc<=cyc+1;
    if(cyc>8000000) $fatal(1,"store capacity watchdog");
    DDRAM_DOUT_READY<=0;
    if(stall_n!=0) stall_n<=stall_n-1;
    if(started) begin
      if(VGA_RD || VGA_WE) $fatal(1,"unexpected device access");
      if(held && ddr_command!==held_command) $fatal(1,"blocked DDR command changed");
      held<=DDRAM_BUSY && (DDRAM_RD || DDRAM_WE);
      held_command<=ddr_command;
      if(DDRAM_RD && DDRAM_WE) $fatal(1,"DDR owners overlap");
      if((DDRAM_RD || DDRAM_WE) && !DDRAM_BUSY) begin
        if(DDRAM_ADDR < BASE/8 || DDRAM_ADDR >= BASE/8+WORDS/2)
          $fatal(1,"DDR address out of range");
        if(DDRAM_WE) begin
          if(DDRAM_BURSTCNT!=1) $fatal(1,"DDR write extent");
          for(int lane=0;lane<8;lane++)
            if(DDRAM_BE[lane]) ram[(int'(DDRAM_ADDR)-BASE/8)*2+lane/4][8*(lane%4)+:8] <= DDRAM_DIN[8*lane+:8];
          writes<=writes+1;
        end else begin
          if(DDRAM_BURSTCNT!=8 || DDRAM_ADDR[2:0]!=0) $fatal(1,"DDR fill extent");
          active<=1; remaining<=8; next_word<=(int'(DDRAM_ADDR)-BASE/8)*2;
          due<=cyc+4+cadence; ddr_reads<=ddr_reads+1;
        end
      end
      if(active && cyc>=due) begin
        DDRAM_DOUT<={ram[next_word+1],ram[next_word]}; DDRAM_DOUT_READY<=1;
        remaining<=remaining-1;next_word<=next_word+2;due<=cyc+cadence;
        if(remaining==1) active<=0;
      end
    end
  end
  task automatic idle();
    int deadline;
    deadline=cyc+SETS+256;
    while(dut.state!=1 || CPU_BUSY || active) begin
      @(negedge CLK);
      if(cyc>deadline) $fatal(1,"idle timeout");
    end
  endtask
  task automatic read_words(input int word_idx,input int count);
    int got,deadline;
    idle(); @(negedge CLK);
    CPU_ADDR=30'((BASE/4)+word_idx);CPU_BURSTCNT=4'(count);CPU_RD=1;
    @(negedge CLK);CPU_RD=0;got=0;deadline=cyc+256;
    while(got<count) begin
      if(CPU_DOUT_READY) begin
        if(CPU_DOUT!==expected[word_idx+got])
          $fatal(1,"read mismatch word=%0d got=%08x expected=%08x",word_idx+got,CPU_DOUT,expected[word_idx+got]);
        got++;reads++;
      end
      if(got<count) @(negedge CLK);
      if(cyc>deadline) $fatal(1,"read timeout");
    end
  endtask
  task automatic write_word(input int word_idx,input reg[3:0] mask,input reg[31:0] value);
    int before_writes,deadline;
    idle();@(negedge CLK);before_writes=writes;
    CPU_ADDR=30'(BASE/4+word_idx);CPU_DIN=value;CPU_BE=mask;CPU_WE=1;
    @(negedge CLK);CPU_WE=0;
    // Block the captured DDR store, then poison all live CPU fields.
    stall_n=6;CPU_ADDR=30'hfffffff;CPU_DIN=~value;CPU_BE=~mask;
    for(int lane=0;lane<4;lane++)
      if(mask[lane]) expected[word_idx][8*lane+:8]=value[8*lane+:8];
    deadline=cyc+256;
    while(writes==before_writes) begin
      @(negedge CLK);
      if(cyc>deadline) $fatal(1,"DDR write timeout");
    end
    idle();
    if(writes!=before_writes+1) $fatal(1,"lost/duplicate DDR store");
    CPU_BE=15;
  endtask
  initial begin
    if(!$value$plusargs("CADENCE=%d",cadence)) cadence=1;
    if(cadence<1 || cadence>3) $fatal(1,"bad cadence");
    foreach(ram[i]) begin ram[i]=32'hb57e0000^(32'(i)*32'h9e3779b9);expected[i]=ram[i];end
    repeat(2) @(negedge CLK);RESET=1;
    repeat(5) @(negedge CLK);RESET=0;
    repeat(SETS+16) @(negedge CLK);started=1;idle();
    // Every set, including all new high bits; all ways and all byte masks.
    for(int set_idx=0;set_idx<SETS;set_idx++) begin
      for(int tag=0;tag<4;tag++) read_words((tag*SETS+set_idx)*16,8);
      for(int mask=0;mask<16;mask++) begin
        int word_idx;
        word_idx=((mask%4)*SETS+set_idx)*16+mask;
        write_word(word_idx,4'(mask),32'h24fe1900^(32'(set_idx)*19+32'(mask)));
        read_words(word_idx,1);
      end
      for(int tag=0;tag<4;tag++) begin
        read_words((tag*SETS+set_idx)*16,8);
        read_words((tag*SETS+set_idx)*16+8,8);
      end
      // A write miss must not destroy an aliased resident line or allocate
      // incoherent data. Later refill must see exactly the written bytes.
      write_word((4*SETS+set_idx)*16+15,4'h5,32'h76543210^32'(set_idx));
      read_words(set_idx*16,8);read_words((4*SETS+set_idx)*16+8,8);
      idle();@(negedge CLK);
      ram[(4*SETS+set_idx)*16+15]^=32'h01804020;
      expected[(4*SETS+set_idx)*16+15]^=32'h01804020;
      l2_inv_addr=25'(BASE/8+(4*SETS+set_idx)*8);l2_inv_pulse=1;
      @(negedge CLK);l2_inv_pulse=0;repeat(4) @(negedge CLK);
      read_words((4*SETS+set_idx)*16+8,8);mutations++;
    end
    idle();
    if(writes!=17*SETS || mutations!=SETS) $fatal(1,"coverage incomplete");
    foreach(ram[i]) if(ram[i]!==expected[i]) $fatal(1,"backing corruption word=%0d",i);
    $display("L2-CAPACITY-STORES-OK sets=%0d cadence=%0d writes=%0d reads=%0d mutations=%0d ddr_reads=%0d",
             SETS,cadence,writes,reads,mutations,ddr_reads);
    $finish;
  end
endmodule
