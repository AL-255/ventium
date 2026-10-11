// Actual old/new core U-operand blocks + decoder + forwarded branch decision.
// No mocked per-instruction admission table or rewritten architectural trace.
`timescale 1ns/1ps
module tb_u_shift_registers;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  logic [7:0] opcode, modrm, immediate;
  logic def16, mode;
  logic [31:0] gpr [0:7], memory_value, flags;
  fpd_t decoded, u, held, v;
  logic use_held;
  logic [31:0] old_alu, old_flags, old_shift, old_previous;
  logic [31:0] new_alu, new_flags, new_shift, new_previous;
  logic old_carry, new_carry, old_taken, new_taken;
  logic [4:0] old_count, new_count;
  int checks=0, shifts=0, memory_ops=0, high_bytes=0, zero_counts=0, held_checks=0;
  decode dec(.ib0(opcode), .ib1(modrm), .ib2(immediate), .ib3(8'h81),
    .ib4(8'h7f), .ib5(8'h00), .ib6(8'h80), .iflags(flags), .def16,
    .cycle_mode(mode), .uop(decoded));
  assign u = use_held ? held : decoded;
  original_u original(.pipe_u_eff(u), .gpr_o(gpr), .mem_rdata(memory_value), .eflags(flags),
    .u_alu(old_alu), .u_flags(old_flags), .u_sh(old_shift), .u_shm1(old_previous),
    .u_shcf(old_carry), .u_shift_cnt(old_count));
  candidate_u candidate(.pipe_u_eff(u), .gpr_o(gpr), .mem_rdata(memory_value), .eflags(flags),
    .u_alu(new_alu), .u_flags(new_flags), .u_sh(new_shift), .u_shm1(new_previous),
    .u_shcf(new_carry), .u_shift_cnt(new_count));
  uv_common old_forward(.eflags(flags), .bcd_eax16(16'd0), .bcd_imm8(8'd1),
    .bcd_alu_op(5'd0), .bcd_ax(), .bcd_flags(), .u_d(u), .v_d(v),
    .u_flags(old_flags), .u_sh(old_shift), .u_shm1(old_previous), .u_shcf(old_carry),
    .v_br_taken_eff(old_taken));
  uv_common new_forward(.eflags(flags), .bcd_eax16(16'd0), .bcd_imm8(8'd1),
    .bcd_alu_op(5'd0), .bcd_ax(), .bcd_flags(), .u_d(u), .v_d(v),
    .u_flags(new_flags), .u_sh(new_shift), .u_shm1(new_previous), .u_shcf(new_carry),
    .v_br_taken_eff(new_taken));

  task automatic check;
    #1;
    checks++;
    if (u.is_shift && (u.is_mem || u.is_load || u.is_store))
      $fatal(1,"U-SHIFT-INVARIANT op=%02x mr=%02x",opcode,modrm);
    if ({old_alu,old_flags,old_taken} !== {new_alu,new_flags,new_taken})
      $fatal(1,"U-SHIFT-MISMATCH alu/forward op=%02x mr=%02x held=%0d",opcode,modrm,use_held);
    if (u.is_shift) begin
      shifts++; high_bytes+=int'(u.w8 && u.dst_hi8); zero_counts+=int'(old_count==0);
      if ({old_shift,old_previous,old_carry,old_count} !==
          {new_shift,new_previous,new_carry,new_count})
        $fatal(1,"U-SHIFT-MISMATCH shift op=%02x mr=%02x count=%0d",opcode,modrm,old_count);
    end
    memory_ops+=int'(u.is_mem); held_checks+=int'(use_held);
  endtask

  initial begin
    logic [7:0] ops [0:5];
    logic [31:0] values [0:5];
    ops='{8'hc0,8'hc1,8'hd0,8'hd1,8'hd2,8'hd3};
    values='{32'd0,32'hffffffff,32'h80000001,32'h7fffffff,32'h80ff7f01,32'ha55a1234};
    use_held=0; held='0; v='0; v.br_cond=1; v.is_branch=1;
    flags=32'ha47; memory_value=32'hdeadcafe;
    for(int r=0;r<8;r++) gpr[r]=32'h81f0a501 ^ (32'h137af2a1*32'(r));
    // All primary opcode/ModR/M bytes, both width/mode settings. Includes
    // memory ALU reads, stores, FP and unsupported forms; their ALUs/flags
    // must be unchanged even when unconsumed shift outputs legitimately differ.
    for(int cm=0;cm<2;cm++) for(int width=0;width<2;width++) begin
      mode=1'(cm); def16=1'(width);
      for(int op=0;op<256;op++) for(int mr=0;mr<256;mr++) begin
        opcode=8'(op); modrm=8'(mr); immediate=8'(op^mr);
        v.cc=4'(op); memory_value=32'hdeadcafe ^ 32'(mr);
        check();
      end
    end
    // Every shift encoding, both default widths, every masked count, actual
    // high-byte aliases, nonzero high words and six operand boundaries.
    mode=0;
    for(int width=0;width<2;width++) for(int op=0;op<6;op++)
      for(int mr=0;mr<256;mr++) for(int n=0;n<32;n++) begin
        def16=1'(width); opcode=ops[op]; modrm=8'(mr); immediate=8'(n+192);
        for(int val=0;val<6;val++) begin
          for(int r=0;r<8;r++) gpr[r]=values[(val+r)%6];
          gpr[1][4:0]=5'(n); flags=32'ha47 ^ (32'(val)*32'h885);
          memory_value=~values[val]; v.cc=4'(n);
          check();
          if (decoded.is_shift && (n==0 || n==1 || n==31)) begin
            // Latch the actual descriptor, change live decode to a memory
            // instruction and exercise stable ownership, not a fabricated
            // descriptor combination. Both are evaluated from the held U.
            held=decoded; use_held=1; opcode=8'h03; modrm=8'h08;
            for(int cc=0;cc<16;cc++) begin v.cc=4'(cc); check(); end
            use_held=0; opcode=ops[op]; modrm=8'(mr);
          end
        end
      end
    if (shifts==0 || memory_ops==0 || high_bytes==0 || zero_counts==0 || held_checks==0)
      $fatal(1,"missing coverage");
    $display("U-SHIFT-REGISTERS-OK checks=%0d shifts=%0d memory=%0d high_byte=%0d zero=%0d held=%0d",
      checks,shifts,memory_ops,high_bytes,zero_counts,held_checks);
    $finish;
  end
endmodule
