// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
// The driver compiles the complete original and transformed ALU packages.
// Exercise every helper count (including >=32), all binary widths/subops,
// both carries, basis vectors, narrow-byte exhaustive and deterministic random.
// This is helper equivalence, not an ISA oracle or a sequential core test.
module tb_carry_rotate_tree;
  int checks = 0, rotate_checks = 0, saturated_checks = 0, unknown_counts = 0;
  logic [31:0] rng = 32'h714fa208;

  task automatic check(input logic [2:0] op, input logic [31:0] value,
      input logic [5:0] count, input logic carry, input logic [2:0] width);
    logic [31:0] old_result, new_result;
    logic old_cf, new_cf;
    begin
      old_result = alu_reference::shrot_result(op,value,count,carry,width);
      old_cf = alu_reference::shrot_cf(op,value,count,carry,width);
      new_result = ventium_alu_pkg::shrot_result(op,value,count,carry,width);
      new_cf = ventium_alu_pkg::shrot_cf(op,value,count,carry,width);
      if (old_result !== new_result || old_cf !== new_cf)
        $fatal(1,"CARRY-ROTATE-MISMATCH op=%h w=%h cnt=%h v=%h cf=%b result=%h/%h carry=%b/%b",
               op,width,count,value,carry,old_result,new_result,old_cf,new_cf);
      checks++;
      if (op == 2 || op == 3) rotate_checks++;
      if (count >= 32) saturated_checks++;
    end
  endtask

  initial begin
    for (int width = 0; width < 8; width++)
      for (int op = 0; op < 8; op++)
        for (int count = 0; count < 64; count++)
          for (int carry = 0; carry < 2; carry++) begin
            check(3'(op),32'd0,6'(count),1'(carry),3'(width));
            check(3'(op),32'hffffffff,6'(count),1'(carry),3'(width));
            for (int bitno = 0; bitno < 32; bitno++)
              check(3'(op),32'd1 << bitno,6'(count),1'(carry),3'(width));
            rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
            check(3'(op),rng,6'(count),1'(carry),3'(width));
          end
    // Exhaustive byte values with intentionally dirty non-operand high bits.
    for (int value = 0; value < 256; value++)
      for (int op = 2; op < 4; op++)
        for (int count = 0; count < 64; count++)
          for (int carry = 0; carry < 2; carry++)
            check(3'(op),32'ha55a0000 | 32'(value),6'(count),1'(carry),3'd1);
    for (int width = 1; width <= 4; width *= 2)
      for (int op = 2; op < 4; op++)
        for (int bitno = 0; bitno < 6; bitno++) begin
          logic [5:0] count;
          count = 6'd31; count[bitno] = 1'bx;
          check(3'(op),32'h76543210,count,1'b1,3'(width)); unknown_counts++;
          count[bitno] = 1'bz;
          check(3'(op),32'h76543210,count,1'b0,3'(width)); unknown_counts++;
        end
    if (checks != 352328 || rotate_checks != 137288 ||
        saturated_checks != 176128 || unknown_counts != 72)
      $fatal(1,"CARRY-ROTATE-COVERAGE checks=%0d rotate=%0d sat=%0d unknown=%0d",
             checks,rotate_checks,saturated_checks,unknown_counts);
    $display("CARRY-ROTATE-TREE-OK checks=%0d rotate=%0d saturated=%0d unknown_counts=%0d",
             checks,rotate_checks,saturated_checks,unknown_counts);
    $finish;
  end
endmodule
