`default_nettype none
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Production-span miter for the VEN_IC_BRAM frontend factoring.  The runner
// generates ic_front_span_extracted.svh from rtl/core/core.sv immediately
// before compiling this test.  That include contains the original
// ic_present/ic_hit_way/ic_byte functions followed by the exact marked
// production implementation; this fixture must never grow a hand-maintained
// copy of either side of that comparison.
`timescale 1ns/1ps

module tb_ic_front_span_miter;
  localparam int IC_SETS = 128;
  localparam int IC_WAYS = 2;
  localparam int IC_LINE = 32;
  localparam int IC_IDXW = $clog2(IC_SETS);
  localparam int IC_WAYW = $clog2(IC_WAYS);
  localparam int IC_TAGW = 32 - 5 - IC_IDXW;

  logic clk;
  initial clk = 1'b0;
  always #1 clk = ~clk;

  // These are the complete dependency surface of the extracted core section.
  logic [31:0] flin;
  wire  [31:0] flin_nl = {flin[31:5], 5'd0} + 32'd32;
  logic [IC_TAGW-1:0] ic_tag_o [IC_SETS][IC_WAYS];
  logic                 ic_val_o [IC_SETS][IC_WAYS];
  logic [1:0]           icbp_v;
  logic [IC_IDXW-1:0]   icbp_set [2];
  logic [IC_WAYW-1:0]   icbp_way [2];
  logic [IC_TAGW-1:0]   icbp_tag [2];
  logic [IC_LINE*8-1:0] ic_rd_lineA, ic_rd_lineB;
  logic [IC_IDXW-1:0]   rdA_set_q, rdB_set_q;
  logic [IC_WAYW-1:0]   rdA_way_q, rdB_way_q;
  logic                 ic_rd_collA, ic_rd_collB;
  // The non-BRAM variant of the original ic_byte function uses these names.
  logic [IC_IDXW-1:0]   ic_rd_setA, ic_rd_setB;

  `include "ic_front_span_extracted.svh"

  logic [31:0] rng_state = 32'h5eeda11c;

  function automatic logic [31:0] prng_next(input logic [31:0] value);
    logic [31:0] x;
    begin
      x = value;
      x = x ^ (x << 13);
      x = x ^ (x >> 17);
      x = x ^ (x << 5);
      prng_next = x;
    end
  endfunction

  task automatic random_word(output logic [31:0] value);
    begin
      rng_state = prng_next(rng_state);
      value = rng_state;
    end
  endtask

  function automatic logic [IC_LINE*8-1:0] patterned_line(
      input logic [31:0] seed);
    logic [IC_LINE*8-1:0] result;
    logic [31:0] byte_word;
    begin
      result = '0;
      for (int byte_index = 0; byte_index < IC_LINE; byte_index++) begin
        byte_word = seed + 32'(byte_index * 29) + 32'h3d;
        result[byte_index*8 +: 8] = byte_word[7:0];
      end
      patterned_line = result;
    end
  endfunction

  task automatic die(input string label, input string detail);
    begin
      $fatal(1, "IC-FRONT-SPAN-MITER %s: %s", label, detail);
    end
  endtask

  task automatic clear_state;
    logic [31:0] word;
    begin
      for (int set_index = 0; set_index < IC_SETS; set_index++) begin
        for (int way_index = 0; way_index < IC_WAYS; way_index++) begin
          random_word(word);
          ic_val_o[set_index][way_index] = 1'b0;
          ic_tag_o[set_index][way_index] = word[IC_TAGW-1:0];
        end
      end
      icbp_v = 2'b00;
      for (int slot = 0; slot < 2; slot++) begin
        random_word(word);
        icbp_set[slot] = word[5 +: IC_IDXW];
        icbp_way[slot] = word[IC_WAYW-1:0];
        icbp_tag[slot] = word[5+IC_IDXW +: IC_TAGW];
      end
      random_word(word); ic_rd_lineA = patterned_line(word ^ 32'ha5a50000);
      random_word(word); ic_rd_lineB = patterned_line(word ^ 32'h5a5a0000);
      random_word(word); rdA_set_q = word[5 +: IC_IDXW];
      random_word(word); rdA_way_q = word[IC_WAYW-1:0];
      random_word(word); rdB_set_q = word[5 +: IC_IDXW];
      random_word(word); rdB_way_q = word[IC_WAYW-1:0];
      random_word(word); ic_rd_collA = word[0];
      random_word(word); ic_rd_collB = word[0];
      random_word(word); ic_rd_setA = word[5 +: IC_IDXW];
      random_word(word); ic_rd_setB = word[5 +: IC_IDXW];
    end
  endtask

  task automatic install_cache(input logic [31:0] addr,
                               input logic [IC_WAYW-1:0] way);
    begin
      ic_val_o[addr[5 +: IC_IDXW]][way] = 1'b1;
      ic_tag_o[addr[5 +: IC_IDXW]][way] = addr[5+IC_IDXW +: IC_TAGW];
    end
  endtask

  task automatic install_bypass(input int slot, input logic [31:0] addr,
                                input logic [IC_WAYW-1:0] way);
    begin
      icbp_v[slot] = 1'b1;
      icbp_set[slot] = addr[5 +: IC_IDXW];
      icbp_tag[slot] = addr[5+IC_IDXW +: IC_TAGW];
      icbp_way[slot] = way;
    end
  endtask

  task automatic set_a_buffer(input logic [31:0] addr,
                               input logic [IC_WAYW-1:0] way,
                               input logic [31:0] seed, input logic collided);
    begin
      rdA_set_q = addr[5 +: IC_IDXW];
      rdA_way_q = way;
      ic_rd_lineA = patterned_line(seed);
      ic_rd_collA = collided;
      ic_rd_setA = addr[5 +: IC_IDXW];
    end
  endtask

  task automatic set_b_buffer(input logic [31:0] addr,
                               input logic [IC_WAYW-1:0] way,
                               input logic [31:0] seed, input logic collided);
    begin
      rdB_set_q = addr[5 +: IC_IDXW];
      rdB_way_q = way;
      ic_rd_lineB = patterned_line(seed);
      ic_rd_collB = collided;
      ic_rd_setB = addr[5 +: IC_IDXW];
    end
  endtask

  task automatic assert_distinct_buffers(input string label);
    begin
      if (ic_rd_lineA === ic_rd_lineB)
        die(label, "test fixture accidentally made A and B byte-identical");
    end
  endtask

`ifdef VEN_IC_BRAM
  task automatic check_front(input string label);
    logic [31:0] addr;
    logic [IC_WAYW:0] want_a, want_b, want_probe;
    logic [7:0] want_byte, got_byte;
    logic want_present;
    begin
      #1;
      want_a = {ic_present(flin), ic_hit_way(flin)};
      want_b = {ic_present(flin_nl), ic_hit_way(flin_nl)};
      if (ic_front_a !== want_a)
        die(label, $sformatf("front A probe got=%b want=%b flin=%08x",
                             ic_front_a, want_a, flin));
      if (ic_front_b !== want_b)
        die(label, $sformatf("front B probe got=%b want=%b flin_nl=%08x",
                             ic_front_b, want_b, flin_nl));

      // Validate each precomputed byte and presence bit against the original
      // generic functions.  This covers every unaligned start offset and the
      // A-to-B crossing of the 22-byte shared span.
      for (int index = 0; index < IC_FRONT_BYTES; index++) begin
        addr = flin + 32'(index);
        want_probe = {ic_present(addr), ic_hit_way(addr)};
        if (ic_front_probe(addr) !== want_probe)
          die(label, $sformatf("probe[%0d] got=%b want=%b addr=%08x",
                               index, ic_front_probe(addr), want_probe, addr));
        want_byte = ic_byte(addr);
        want_present = ic_present(addr);
        if (ic_front_bytes[index] !== want_byte)
          die(label, $sformatf("byte[%0d] got=%02x want=%02x addr=%08x",
                               index, ic_front_bytes[index], want_byte, addr));
        if (ic_front_present_bytes[index] !== want_present)
          die(label, $sformatf("present[%0d] got=%b want=%b addr=%08x",
                               index, ic_front_present_bytes[index], want_present, addr));
      end

      // The two factored return-line muxes must retain the original A/B/stale-A
      // selection for every byte, including colliding/missing identities.
      for (int index = 0; index < IC_LINE; index++) begin
        addr = {flin[31:5], 5'd0} + 32'(index);
        got_byte = ic_front_lineA[index*8 +: 8];
        want_byte = ic_byte(addr);
        if (got_byte !== want_byte)
          die(label, $sformatf("lineA[%0d] got=%02x want=%02x addr=%08x",
                               index, got_byte, want_byte, addr));
        addr = flin_nl + 32'(index);
        got_byte = ic_front_lineB[index*8 +: 8];
        want_byte = ic_byte(addr);
        if (got_byte !== want_byte)
          die(label, $sformatf("lineB[%0d] got=%02x want=%02x addr=%08x",
                               index, got_byte, want_byte, addr));
      end

      // The U raw path uniquely zeroes an unavailable byte.  V and slow/raw
      // consumers intentionally retain stale byte values; both forms are
      // checked explicitly rather than assuming a resident line.
      for (int index = 0; index < 7; index++) begin
        addr = flin + 32'(index);
        want_byte = ic_present(addr) ? ic_byte(addr) : 8'd0;
        got_byte = ic_front_present_bytes[index] ? ic_front_bytes[index] : 8'd0;
        if (got_byte !== want_byte)
          die(label, $sformatf("U[%0d] got=%02x want=%02x", index, got_byte, want_byte));
      end
      for (int ulen = 0; ulen <= 15; ulen++) begin
        for (int index = 0; index < 7; index++) begin
          addr = flin + 32'(ulen + index);
          got_byte = ic_front_bytes[ulen + index];
          want_byte = ic_byte(addr);
          if (got_byte !== want_byte)
            die(label, $sformatf("V ulen=%0d index=%0d got=%02x want=%02x",
                                 ulen, index, got_byte, want_byte));
        end
      end
      for (int index = 0; index < 16; index++) begin
        addr = flin + 32'(index);
        if (ic_front_bytes[index] !== ic_byte(addr))
          die(label, $sformatf("slow/ref/capture[%0d] mismatch", index));
      end
    end
  endtask

  task automatic configure_resident_pair(input logic [31:0] start_addr);
    logic [31:0] line_a_addr, line_b_addr;
    begin
      clear_state();
      flin = start_addr;
      line_a_addr = {start_addr[31:5], 5'd0};
      line_b_addr = line_a_addr + 32'd32;
      install_cache(line_a_addr, 1'b0);
      install_cache(line_b_addr, 1'b1);
      set_a_buffer(line_a_addr, 1'b0, (32'ha0010011 ^ line_a_addr), 1'b0);
      set_b_buffer(line_b_addr, 1'b1, (32'hb00200a7 ^ line_b_addr), 1'b0);
      assert_distinct_buffers("resident-pair-fixture");
    end
  endtask

  task automatic directed_cases;
    logic [31:0] line_a_addr, line_b_addr;
    begin
      // Every starting byte position, including set 127 -> set 0, uses the
      // resident pair.  The second loop proves the full 32-bit next-line wrap.
      for (int low = 0; low < 32; low++) begin
        configure_resident_pair(32'h00100fe0 + 32'(low));
        check_front($sformatf("set127-wrap-low%0d", low));
        configure_resident_pair(32'hffffffe0 + 32'(low));
        check_front($sformatf("addr32-wrap-low%0d", low));
      end

      // A nonresident span retains stale A for direct V/slow/capture reads,
      // while U is presence-gated to zero.
      clear_state();
      flin = 32'h12345ffb;
      set_a_buffer(32'h00000200, 1'b0, 32'hdead0001, 1'b0);
      set_b_buffer(32'h00000220, 1'b1, 32'hbeef0002, 1'b0);
      check_front("miss-stale-A-and-U-zero");

      // Duplicate valid tags are legal metadata corruption/transient state in
      // this oracle: the highest matching cache way wins.
      clear_state();
      flin = 32'h1234561d;
      line_a_addr = {flin[31:5], 5'd0};
      line_b_addr = line_a_addr + 32'd32;
      install_cache(line_a_addr, 1'b0);
      install_cache(line_a_addr, 1'b1);
      install_cache(line_b_addr, 1'b0);
      install_cache(line_b_addr, 1'b1);
      set_a_buffer(line_a_addr, 1'b0, 32'hc0010011, 1'b0);
      set_b_buffer(line_a_addr, 1'b1, 32'hc00200a7, 1'b0);
      assert_distinct_buffers("duplicate-cache-fixture");
      check_front("duplicate-cache-last-way-wins");

`ifndef VEN_IC_NO_FETCH_BYPASS
      // Bypass slot 0 overrides cache metadata; slot 1 then overrides slot 0.
      install_bypass(0, line_a_addr, 1'b0);
      check_front("bypass-slot0-overrides-cache");
      install_bypass(1, line_a_addr, 1'b1);
      check_front("bypass-slot1-overrides-slot0");
`endif

      // Same returned identity prefers clean A; a collided A permits clean B;
      // two collided/missing identities use stale A exactly as ic_byte does.
      clear_state();
      flin = 32'h02aaabfc;
      line_a_addr = {flin[31:5], 5'd0};
      install_cache(line_a_addr, 1'b0);
      set_a_buffer(line_a_addr, 1'b0, 32'hd0010011, 1'b0);
      set_b_buffer(line_a_addr, 1'b0, 32'hd00200a7, 1'b0);
      assert_distinct_buffers("same-identity-fixture");
      check_front("same-identity-A-priority");
      ic_rd_collA = 1'b1;
      check_front("same-identity-A-collision-B-selected");
      ic_rd_collB = 1'b1;
      check_front("same-identity-both-collide-stale-A");
    end
  endtask

  task automatic random_state;
    logic [31:0] word;
    begin
      clear_state();
      random_word(word); flin = word;
      for (int set_index = 0; set_index < IC_SETS; set_index++) begin
        for (int way_index = 0; way_index < IC_WAYS; way_index++) begin
          random_word(word); ic_val_o[set_index][way_index] = word[0];
          random_word(word); ic_tag_o[set_index][way_index] = word[IC_TAGW-1:0];
        end
      end
      for (int slot = 0; slot < 2; slot++) begin
        random_word(word); icbp_v[slot] = word[0];
        random_word(word); icbp_set[slot] = word[5 +: IC_IDXW];
        random_word(word); icbp_way[slot] = word[IC_WAYW-1:0];
        random_word(word); icbp_tag[slot] = word[IC_TAGW-1:0];
      end
      random_word(word); ic_rd_lineA = patterned_line(word);
      random_word(word); ic_rd_lineB = patterned_line(word);
      random_word(word); rdA_set_q = word[5 +: IC_IDXW];
      random_word(word); rdA_way_q = word[IC_WAYW-1:0];
      random_word(word); rdB_set_q = word[5 +: IC_IDXW];
      random_word(word); rdB_way_q = word[IC_WAYW-1:0];
      random_word(word); ic_rd_collA = word[0];
      random_word(word); ic_rd_collB = word[0];
    end
  endtask

  task automatic targeted_random_cases;
    logic [31:0] word, line_a_addr, line_b_addr, unrelated_addr;
    logic [IC_WAYW-1:0] way_a, way_b;
    logic [1:0] collision_bits;
    begin
      // Unlike the broad randomized states below, each of these configurations
      // deliberately hits both current and next lines.  It covers all low-five
      // start offsets, every collision combination, and normal/swapped/same/
      // unrelated registered return-buffer ownership.  Bypass modes alter the
      // selected way without changing cache geometry.
      for (int low = 0; low < 32; low++) begin
        for (int owner = 0; owner < 4; owner++) begin
          for (int collision = 0; collision < 4; collision++) begin
            clear_state();
            random_word(word);
            flin = {word[31:5], low[4:0]};
            line_a_addr = {flin[31:5], 5'd0};
            line_b_addr = line_a_addr + 32'd32;
            unrelated_addr = line_b_addr + 32'd32;
            install_cache(line_a_addr, 1'b0);
            install_cache(line_b_addr, 1'b1);
`ifndef VEN_IC_NO_FETCH_BYPASS
            case ((low + owner + collision) & 3)
              1: install_bypass(0, line_a_addr, 1'b1);
              2: install_bypass(1, line_b_addr, 1'b0);
              3: begin
                install_bypass(0, line_a_addr, 1'b1);
                install_bypass(1, line_a_addr, 1'b0);
              end
              default: begin end
            endcase
`endif
            way_a = ic_hit_way(line_a_addr);
            way_b = ic_hit_way(line_b_addr);
            collision_bits = collision[1:0];
            case (owner)
              0: begin
                set_a_buffer(line_a_addr, way_a, 32'h71000011 ^ word,
                             collision_bits[0]);
                set_b_buffer(line_b_addr, way_b, 32'h720000a7 ^ word,
                             collision_bits[1]);
              end
              1: begin
                set_a_buffer(line_b_addr, way_b, 32'h73000011 ^ word,
                             collision_bits[0]);
                set_b_buffer(line_a_addr, way_a, 32'h740000a7 ^ word,
                             collision_bits[1]);
              end
              2: begin
                set_a_buffer(line_a_addr, way_a, 32'h75000011 ^ word,
                             collision_bits[0]);
                set_b_buffer(line_a_addr, way_a, 32'h760000a7 ^ word,
                             collision_bits[1]);
              end
              default: begin
                set_a_buffer(unrelated_addr, 1'b1, 32'h77000011 ^ word,
                             collision_bits[0]);
                set_b_buffer(line_a_addr, way_a, 32'h780000a7 ^ word,
                             collision_bits[1]);
              end
            endcase
            assert_distinct_buffers($sformatf("targeted-fixture-low%0d-owner%0d-coll%0d",
                                                low, owner, collision));
            check_front($sformatf("targeted-low%0d-owner%0d-coll%0d",
                                  low, owner, collision));
          end
        end
      end
    end
  endtask

  task automatic turnover_at_clock(input int transition_index);
    logic [31:0] word, next_flin, next_line_b;
    logic [IC_IDXW-1:0] set_a, set_b;
    logic [IC_TAGW-1:0] tag_a, tag_b;
    begin
      random_word(next_flin);
      set_a = next_flin[5 +: IC_IDXW];
      tag_a = next_flin[5+IC_IDXW +: IC_TAGW];
      next_line_b = {next_flin[31:5], 5'd0} + 32'd32;
      set_b = next_line_b[5 +: IC_IDXW];
      tag_b = next_line_b[5+IC_IDXW +: IC_TAGW];
      check_front($sformatf("turnover-%0d-before", transition_index));
      random_word(word);
      @(posedge clk);
      // This is fixture turnover sampled at a real clock boundary, not a
      // claim about RTL nonblocking-assignment ordering.  The miter checks the
      // complete pre- and post-turnover combinational configurations against
      // the original oracle; temporal cache protocol is covered elsewhere.
      flin = next_flin;
      ic_val_o[set_a][0] = 1'b1;
      ic_tag_o[set_a][0] = tag_a;
      ic_val_o[set_b][1] = word[0];
      ic_tag_o[set_b][1] = tag_b;
      icbp_v[0] = word[1];
      icbp_set[0] = set_a;
      icbp_tag[0] = tag_a;
      icbp_way[0] = word[2];
      icbp_v[1] = word[3];
      icbp_set[1] = set_b;
      icbp_tag[1] = tag_b;
      icbp_way[1] = word[4];
      rdA_set_q = set_a;
      rdA_way_q = word[5];
      rdB_set_q = set_b;
      rdB_way_q = word[6];
      ic_rd_collA = word[7];
      ic_rd_collB = word[8];
      ic_rd_lineA = patterned_line(word ^ 32'h11110011);
      ic_rd_lineB = patterned_line(word ^ 32'h222200a7);
      assert_distinct_buffers($sformatf("turnover-%0d-fixture", transition_index));
      #1;
      check_front($sformatf("turnover-%0d-after", transition_index));
    end
  endtask
`else
  task automatic nonbram_smoke(input string label);
    logic [31:0] addr;
    logic [7:0] want_byte;
    begin
      clear_state();
      flin = 32'h0123451d;
      ic_rd_setA = flin[5 +: IC_IDXW];
      ic_rd_setB = flin_nl[5 +: IC_IDXW];
      ic_rd_lineA = patterned_line(32'h11111111);
      ic_rd_lineB = patterned_line(32'h22222222);
      for (int index = 0; index < 64; index++) begin
        addr = flin + 32'(index);
        want_byte = (addr[5 +: IC_IDXW] == ic_rd_setA)
                    ? ic_rd_lineA[{addr[4:0],3'b000} +: 8]
                    : ic_rd_lineB[{addr[4:0],3'b000} +: 8];
        if (ic_byte(addr) !== want_byte)
          die(label, $sformatf("non-BRAM oracle byte[%0d] mismatch", index));
      end
      $display("IC-FRONT-SPAN-NONBRAM-SMOKE-OK %s", label);
    end
  endtask
`endif

  initial begin
`ifdef VEN_IC_BRAM
    directed_cases();
    for (int iteration = 0; iteration < 192; iteration++) begin
      random_state();
      check_front($sformatf("random-%0d", iteration));
    end
    targeted_random_cases();
    for (int transition_index = 0; transition_index < 96; transition_index++) begin
      random_state();
      turnover_at_clock(transition_index);
    end
    $display("IC-FRONT-SPAN-MITER-OK bypass=%0d",
`ifdef VEN_IC_NO_FETCH_BYPASS
             0
`else
             1
`endif
    );
`else
    nonbram_smoke("generic-ic-byte-only");
`endif
    $finish;
  end
endmodule

`default_nettype wire
