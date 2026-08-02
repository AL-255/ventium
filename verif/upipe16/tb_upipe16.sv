// 16-bit U-pipe equivalence test (task #60). The fast path and the slow path compute from the
// SAME pure functions in ventium_alu_pkg, so for any decoded op they must agree EXACTLY once the
// fast path is told the operand width. This drives u_pipe with w16=1 and compares against the
// slow path's own sequence (core.sv:2028-2034): mask both operands with wmask(...,q_w), then
// alu_result / flags_next at that width. Any disagreement IS a missing operand-size layer.
// Runs in milliseconds and needs no boot -- which is the entire point after eight build-and-boot
// cycles returned one bit each.
`timescale 1ns/1ps
module tb_upipe16;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;

  fpd_t d;
  logic [31:0] dst, src, fl;
  logic [31:0] u_alu, u_flags, u_sh, u_shm1;
  logic        u_shcf;
  u_pipe dut(.u_d(d), .u_dst_val(dst), .u_src_val(src), .eflags(fl),
             .u_alu(u_alu), .u_flags(u_flags), .u_sh(u_sh), .u_shm1(u_shm1), .u_shcf(u_shcf));

  int fails = 0, checks = 0;
  // slow-path reference, verbatim from core.sv:2028-2034 at q_w = 3'd2
  task automatic ref_chk(string name);
    logic [31:0] a_ref, b_ref, alu_ref, fl_ref;
    #1;
    a_ref = wmask(dst, 3'd2);
    b_ref = (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) ? 32'd1
          : d.use_imm ? wmask(d.imm, 3'd2) : wmask(src, 3'd2);
    alu_ref = alu_result(d.alu_op, a_ref, b_ref, fl[0]);
    fl_ref  = flags_next(d.alu_op, a_ref, b_ref, alu_ref, fl, 3'd2);
    checks++;
    if (u_alu !== alu_ref) begin
      $display("FAIL %-18s alu   fast=%08x slow=%08x  (dst=%08x b=%08x)", name, u_alu, alu_ref, dst, b_ref);
      fails++;
    end else if (u_flags !== fl_ref) begin
      $display("FAIL %-18s flags fast=%08x slow=%08x  (alu=%08x)", name, u_flags, fl_ref, alu_ref);
      fails++;
    end
  endtask

  initial begin
    d = '0; d.w16 = 1'b1; fl = 32'h2;
    // sweep the common BIOS ALU ops over boundary-sensitive operands
    for (int op = 0; op < 8; op++) begin
      d.alu_op = op[4:0]; d.use_imm = 1'b0;
      foreach_operands: begin
        logic [31:0] vals [0:7];
        vals[0]=32'h0000_0000; vals[1]=32'h0000_FFFF; vals[2]=32'h0000_8000; vals[3]=32'h0000_7FFF;
        vals[4]=32'hDEAD_0001; vals[5]=32'hBEEF_FFFF; vals[6]=32'h1234_8001; vals[7]=32'hFFFF_0100;
        for (int i = 0; i < 8; i++) for (int j = 0; j < 8; j++) begin
          dst = vals[i]; src = vals[j];
          ref_chk($sformatf("op%0d reg", op));
        end
      end
    end
    // immediate forms (the upper half of dst must not leak into the result or the flags)
    d.use_imm = 1'b1;
    for (int op = 0; op < 8; op++) begin
      d.alu_op = op[4:0];
      d.imm = 32'h0000_8001; dst = 32'hCAFE_7FFF; src = 0; ref_chk($sformatf("op%0d imm", op));
      d.imm = 32'h0000_FFFF; dst = 32'h1234_0001; src = 0; ref_chk($sformatf("op%0d imm", op));
    end
    // INC/DEC (fixed operand 1, CF preserved)
    d.use_imm = 1'b0;
    d.alu_op = ALU_INC; dst = 32'hAAAA_FFFF; ref_chk("INC");
    d.alu_op = ALU_DEC; dst = 32'hAAAA_0000; ref_chk("DEC");
    $display("\n%s  (%0d checks, %0d failure(s))",
             fails==0 ? "UPIPE16: PASS" : "UPIPE16: FAIL", checks, fails);
    $finish;
  end
endmodule
