`timescale 1ns/1ps
module tb_p54_dual_agu;
  import ventium_decode_pkg::*;
  fpd_t u, v;
  logic [31:0] gpr [8];
  logic [31:0] u_ea, v_ea;
  int checks = 0;
  ven_p54_dual_agu dut (.*);

  function automatic logic [31:0] reference_ea(input fpd_t d);
    logic [31:0] b, i;
    b = d.mem_base_en ? gpr[d.base] : 32'd0;
    i = d.mem_index_en ? gpr[d.mem_index] << d.mem_scale : 32'd0;
    return (b + d.mem_disp) + i;
  endfunction

  initial begin
    u = '0; v = '0;
    gpr[0] = 32'h00000000;
    gpr[1] = 32'hffffffff;
    gpr[2] = 32'h80000000;
    gpr[3] = 32'h7fffffff;
    gpr[4] = 32'h12345678;
    gpr[5] = 32'hfedcba98;
    gpr[6] = 32'h00000fff;
    gpr[7] = 32'hfffff000;
    for (int base = 0; base < 8; base++) begin
      for (int index = 0; index < 8; index++) begin
        for (int scale = 0; scale < 4; scale++) begin
          for (int mode = 0; mode < 4; mode++) begin
            u.mem_base_en = mode[0];
            u.mem_index_en = mode[1];
            u.base = 3'(base);
            u.mem_index = 3'(index);
            u.mem_scale = 2'(scale);
            u.mem_disp = 32'h80000000 + 32'(checks * 32'h10203);
            v.mem_base_en = mode[1];
            v.mem_index_en = mode[0];
            v.base = 3'(index);
            v.mem_index = 3'(base);
            v.mem_scale = 2'(3 - scale);
            v.mem_disp = 32'hffffffff - 32'(checks * 32'hc10d);
            #1;
            if (u_ea !== reference_ea(u) || v_ea !== reference_ea(v))
              $fatal(1, "dual AGU mismatch case=%0d U=%h/%h V=%h/%h",
                     checks, u_ea, reference_ea(u), v_ea, reference_ea(v));
            checks++;
          end
        end
      end
    end
    $display("P54-DUAL-AGU-OK checks=%0d", checks);
    $finish;
  end
endmodule
