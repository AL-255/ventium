`timescale 1ns/1ps
// Real platform cache, cold fills and independent byte-addressed memory oracle.
// Capacity is measured without changing any core cache or transport policy.
module tb_l2_capacity;
  parameter integer SETS = 128;
  localparam integer BASE = 'h200000;
  reg CLK = 0;
  always #5 CLK = ~CLK;
  reg RESET = 0, DISABLE = 0;
  reg l2_inv_pulse = 0;
  reg [24:0] l2_inv_addr = 0;
  reg [29:0] CPU_ADDR = 0;
  reg [31:0] CPU_DIN = 0;
  wire [31:0] CPU_DOUT;
  wire CPU_DOUT_READY, CPU_BUSY;
  reg [3:0] CPU_BE = 15, CPU_BURSTCNT = 8;
  reg CPU_RD = 0, CPU_WE = 0;
  wire [24:0] DDRAM_ADDR;
  wire [63:0] DDRAM_DIN;
  reg [63:0] DDRAM_DOUT = 0;
  reg DDRAM_DOUT_READY = 0;
  wire [7:0] DDRAM_BE, DDRAM_BURSTCNT;
  reg DDRAM_BUSY = 0;
  wire DDRAM_RD, DDRAM_WE;
  wire [16:0] VGA_ADDR;
  reg [7:0] VGA_DIN = 0;
  wire [7:0] VGA_DOUT;
  reg [2:0] VGA_MODE = 0;
  wire VGA_RD, VGA_WE;
  reg [5:0] VGA_WR_SEG = 0, VGA_RD_SEG = 0;
  reg VGA_FB_EN = 0, uma_ram = 0;

  l2_cache #(.ADDRBITS(24)
`ifdef L2_CAPACITY_PARAM
    ,.CACHE_SETS(SETS)
`endif
  ) dut (.*);

  integer cyc = 0, commands = 0, beat = 0, due = 0;
  integer beats_sent = 0;
  integer work_lines = 1024, seed = 1, words = 8, gap = 1;
  bit active = 0;
  reg [24:0] backing_base = 0;
  // External writer epochs indexed by the physical 64-byte line, not DUT tags.
  reg [31:0] epochs [0:8191];
  integer reference_lines [0:SETS-1][0:3];
  integer checked_reads = 0;
  function automatic [31:0] expected32(input integer byte_addr);
    expected32 = (32'hb57e0000 ^ (32'(byte_addr) * 32'h9e3779b9)) ^
                 epochs[(byte_addr-BASE) >> 6];
  endfunction
  function automatic [63:0] expected64(input integer word_addr);
    expected64 = {expected32(word_addr*8+4), expected32(word_addr*8)};
  endfunction

  // Same one-command/eight-64b-beat contract for every cache size. Holding
  // the tail and varying beat gaps tests the existing streaming response path.
  always @(posedge CLK) begin
    cyc <= cyc + 1;
    DDRAM_DOUT_READY <= 0;
    if (cyc > 4000000) $fatal(1,"capacity watchdog");
    if (DDRAM_WE || VGA_RD || VGA_WE) $fatal(1,"unexpected side effect");
    if (DDRAM_RD && !active) begin
      if (DDRAM_BURSTCNT != 8 || DDRAM_ADDR[2:0] != 0)
        $fatal(1,"wrong backing fill extent");
      commands <= commands + 1;
      backing_base <= DDRAM_ADDR;
      beat <= 0;
      due <= cyc + 4 + seed;
      active <= 1;
    end
    if (active && cyc >= due) begin
      beats_sent <= beats_sent + 1;
      DDRAM_DOUT <= expected64(int'(backing_base) + beat);
      DDRAM_DOUT_READY <= 1;
      if (beat == 7) active <= 0;
      else begin
        beat <= beat + 1;
        due <= cyc + ((beat == 3) ? (7+seed) : (1+seed));
      end
    end
  end

  task automatic idle();
    integer deadline;
    deadline = cyc + SETS + 200;
    while (dut.state != 1 || CPU_BUSY || active) begin
      @(negedge CLK);
      if (cyc >= deadline) $fatal(1,"idle deadline state=%0d",dut.state);
    end
  endtask

  task automatic read_line(input integer line_idx, input integer offset);
    integer n, deadline, address, set_idx, hit_pos, before_commands;
    idle();
    repeat (gap) @(negedge CLK);
    set_idx = line_idx % SETS;
    hit_pos = 4;
    for (int way=0; way<4; way++)
      if (reference_lines[set_idx][way] == line_idx) hit_pos = way;
    before_commands = commands;
    address = BASE + line_idx*64 + offset*4;
    CPU_ADDR = 30'(address >> 2);
    CPU_BURSTCNT = 4'(words);
    CPU_RD = 1;
    @(negedge CLK);
    CPU_RD = 0;
    n = 0;
    deadline = cyc + 250;
    while (n != words) begin
      if (CPU_DOUT_READY) begin
        if (CPU_DOUT !== expected32(address+n*4))
          $fatal(1,"wrong data line=%0d word=%0d got=%08x exp=%08x",line_idx,offset+n,
                 CPU_DOUT,expected32(address+n*4));
        n = n + 1;
      end
      if (n != words) @(negedge CLK);
      if (cyc >= deadline) $fatal(1,"read deadline line=%0d n=%0d",line_idx,n);
    end
    idle();
    if (commands-before_commands != ((hit_pos==4) ? 1 : 0))
      $fatal(1,"independent LRU mismatch read=%0d line=%0d hit_pos=%0d commands=%0d",
             checked_reads,line_idx,hit_pos,commands-before_commands);
    for (int way=3; way>0; way--)
      if (way <= hit_pos) reference_lines[set_idx][way] = reference_lines[set_idx][way-1];
    reference_lines[set_idx][0] = line_idx;
    checked_reads = checked_reads + 1;
  endtask

  integer first_commands, first_cyc, warm_commands, warm_clocks, mutations;
  integer index;
  integer observed_misses = 0;
  integer lru_write_owner = 0;
  reg [31:0] rng;
  integer poison_start, poison_index;
  always @(posedge CLK) begin
    // LRU data and enable are registered. A later request must not redirect
    // a pending write to its own set, including a one-word, zero-idle hit.
`ifdef CHECK_LRU_WRITE_OWNER
    if (dut.LRU_we && cyc > SETS+20) begin
`ifdef LRU_SEPARATE_WRITE_OWNER
      if (dut.LRU_wraddr != lru_write_owner)
`else
      if (dut.LRU_addr != lru_write_owner)
`endif
        $fatal(1,"LRU write redirected away from its captured rank data owner");
    end
`endif
    lru_write_owner <= (dut.state == 0) ? int'(dut.update_tag_addr) : int'(dut.LRU_addr);
`ifdef VEN_L2_STREAM_CWF
    if (dut.state == 3 && dut.scw_candidate && !dut.force_next && !dut.scw_cache_hit_now) begin
      if (observed_misses < 8)
        $display("L2-VICTIM cyc=%0d request_set=%0d lru_set=%0d ranks=%0d,%0d,%0d,%0d",
                 cyc,dut.read_addr[dut.LINEMASKMSB:dut.LINEMASKLSB],dut.LRU_addr,
                 dut.LRU_out[0],dut.LRU_out[1],dut.LRU_out[2],dut.LRU_out[3]);
      observed_misses <= observed_misses + 1;
`ifdef CHECK_LRU_OWNER
      if (dut.LRU_addr != dut.read_addr[dut.LINEMASKMSB:dut.LINEMASKLSB])
        $fatal(1,"streaming victim used another set's LRU state");
`endif
    end
`endif
  end
  initial begin
    if (!$value$plusargs("LINES=%d",work_lines)) work_lines = 1024;
    if (!$value$plusargs("SEED=%d",seed)) seed = 1;
    if (!$value$plusargs("WORDS=%d",words)) words = 8;
    if (!$value$plusargs("GAP=%d",gap)) gap = 1;
    if ((work_lines != 512 && work_lines != 1024 && work_lines != 2048 && work_lines != 4096) ||
        seed < 1 || seed > 2 || words < 1 || words > 8 || gap < 0 || gap > 1)
      $fatal(1,"bad test parameters");
    foreach (epochs[i]) epochs[i] = 0;
    foreach (reference_lines[s,w]) reference_lines[s][w] = -1;
    repeat(2) @(negedge CLK);
    RESET = 1;
    repeat(5) @(negedge CLK);
    RESET = 0;
    repeat(SETS+16) @(negedge CLK);
    idle();
    // Every line is new; this also exercises all four ways and tag boundaries.
    for (int i=0; i<work_lines; i++) read_line(i,0);
    if (commands != work_lines) $fatal(1,"wrong cold fill count %0d",commands);
    first_commands = commands;
    first_cyc = cyc;
    // Switch to the OTHER 32-byte half: the line is still exactly 64 bytes.
    for (int i=0; i<work_lines; i++) read_line(i,8);
    warm_commands = commands-first_commands;
    warm_clocks = cyc-first_cyc;
    if (work_lines <= SETS*4) begin
      if (warm_commands != 0) $fatal(1,"resident footprint missed %0d",warm_commands);
    end else if (warm_commands != work_lines)
      $fatal(1,"overflow control did not thrash: %0d/%0d",warm_commands,work_lines);

    // Exercise invalidation indexing beyond the original 7-bit set field.
    // Backing data changes BEFORE the pulse; the next read must refetch it.
    mutations = 0;
    for (int bitno=0; bitno<11; bitno++) begin
      index = ((1 << bitno)-1) % work_lines;
      read_line(index,0);
      idle();
      @(negedge CLK);
      epochs[index] = epochs[index] ^ (32'h13579bdf + 32'(bitno));
      for (int way=0; way<4; way++) reference_lines[index % SETS][way] = -1;
      l2_inv_addr = 25'((BASE + index*64) >> 3);
      l2_inv_pulse = 1;
      @(negedge CLK);
      l2_inv_pulse = 0;
      repeat(4) @(negedge CLK);
      first_commands = commands;
      read_line(index,0);
      if (commands != first_commands+1) $fatal(1,"invalidation missed high set index=%0d",index);
      mutations = mutations + 1;
    end
    // Exercise true replacement order, especially a hit immediately followed
    // by a fifth tag of the SAME set. No DUT RAM or internal state is forced.
    for (int setno=0; setno<SETS; setno++) begin
      for (int tagno=0; tagno<4; tagno++) read_line(setno+SETS*tagno,0);
      read_line(setno,0);
      read_line(setno+SETS*4,0);
      read_line(setno,0);
      read_line(setno+SETS*2,0);
      read_line(setno+SETS,0);
    end
    rng = 32'(seed);
    for (int trial=0; trial<4096; trial++) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      read_line(int'((rng >> 8) % (SETS*5)), int'((rng >> 1) & 1)*8);
    end
`ifdef VEN_L2_STREAM_CWF
    // Poison every possible returning DDR beat. No backing data is changed
    // while a burst is in flight: the assertion concerns tag publication.
    // Only the any-offset stream handles all short requests; lower-only
    // coverage uses eight-word aligned requests.
`ifndef VEN_L2_STREAM_ANY
    if (words == 8) begin
`endif
    for (int poison_beat=0; poison_beat<8; poison_beat++) begin
      poison_index = SETS*6 + poison_beat;
      idle();
      @(negedge CLK);
      l2_inv_addr = 25'((BASE+poison_index*64)>>3);
      l2_inv_pulse = 1;
      @(negedge CLK);
      l2_inv_pulse = 0;
      repeat (4) @(negedge CLK);
      for (int way=0; way<4; way++) reference_lines[poison_index % SETS][way] = -1;
      poison_start = beats_sent;
      fork
        read_line(poison_index,0);
        begin
          while (beats_sent < poison_start+poison_beat+1) @(negedge CLK);
          l2_inv_pulse = 1;
          @(negedge CLK);
          l2_inv_pulse = 0;
        end
      join
      for (int way=0; way<4; way++) reference_lines[poison_index % SETS][way] = -1;
      read_line(poison_index,0);
    end
`ifndef VEN_L2_STREAM_ANY
    end
`endif
`endif
    // A second real reset must reinitialize all replacement ranks and tags.
    idle();
    @(negedge CLK);
    RESET = 1;
    repeat (5) @(negedge CLK);
    RESET = 0;
    foreach (reference_lines[s,w]) reference_lines[s][w] = -1;
    repeat (SETS+16) @(negedge CLK);
    for (int tagno=0; tagno<5; tagno++) read_line(SETS*tagno,0);
    for (int tagno=1; tagno<5; tagno++) read_line(SETS*tagno,8);
    $display("L2-CAPACITY-OK sets=%0d lines=%0d seed=%0d warm_misses=%0d warm_clocks=%0d mutations=%0d words=%0d gap=%0d",
             SETS,work_lines,seed,warm_commands,warm_clocks,mutations,words,gap);
    $finish;
  end
endmodule
