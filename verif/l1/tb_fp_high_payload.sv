`timescale 1ns/1ps
module tb;
  logic seam_core_rst_n, core_req, core_smram_deny, core_route_deny;
  logic dma_drain_stall, l1d_c_ack, core_d_l1c, core_d_l1c_last;
  logic cr0_cd, l1d_c_rdata_hi_valid;
  wire l1d_c_req, core_rdata_hi_valid;
  logic [31:0] l1d_c_rdata_hi;
  wire [31:0] old_data, new_data;
  int checks=0, valid_checks=0, denied_checks=0, early_payloads=0;
  // SOURCE_EXPRESSIONS

  task automatic check;
    #1;
    checks++;
    if (core_rdata_hi_valid === 1'b1) begin
      valid_checks++;
      if (new_data !== old_data)
        $fatal(1, "VALID-PAYLOAD mismatch old=%08x new=%08x",old_data,new_data);
    end
    if (seam_core_rst_n === 1'b0 || core_smram_deny === 1'b1 || core_route_deny === 1'b1) begin
      denied_checks++;
      if (new_data !== 32'd0)
        $fatal(1, "DENIED-PAYLOAD exposed reset/denied data");
    end
    if (core_rdata_hi_valid === 1'b0 && new_data !== old_data)
      early_payloads++;
  endtask

  initial begin
    for (int controls=0;controls<1024;controls++) begin
      {seam_core_rst_n,core_req,core_smram_deny,core_route_deny,dma_drain_stall,
       l1d_c_ack,core_d_l1c,core_d_l1c_last,cr0_cd,l1d_c_rdata_hi_valid}=10'(controls);
      l1d_c_rdata_hi=0; check();
      l1d_c_rdata_hi='1; check();
      for (int bitno=0;bitno<32;bitno++) begin
        l1d_c_rdata_hi=32'd1<<bitno; check();
      end
      for (int sample=0;sample<8;sample++) begin
        l1d_c_rdata_hi=$urandom(); check();
      end
      l1d_c_rdata_hi='x; check();
      l1d_c_rdata_hi='z; check();
    end
    // Four-state controls: lack of a valid response never grants consumption.
    // Definite reset/denial still blanks data even with other unknown controls.
    for (int control=0;control<10;control++) begin
      {seam_core_rst_n,core_req,core_smram_deny,core_route_deny,dma_drain_stall,
       l1d_c_ack,core_d_l1c,core_d_l1c_last,cr0_cd,l1d_c_rdata_hi_valid}=10'b1100011101;
      case(control)
        0: seam_core_rst_n='x; 1: core_req='x;
        2: core_smram_deny='x; 3: core_route_deny='x;
        4: dma_drain_stall='x; 5: l1d_c_ack='x;
        6: core_d_l1c='x; 7: core_d_l1c_last='x;
        8: cr0_cd='x; 9: l1d_c_rdata_hi_valid='x;
      endcase
      l1d_c_rdata_hi=32'h76543210; check();
      seam_core_rst_n=0; check();
    end
    if (checks != 45076 || valid_checks != 44 || early_payloads == 0 || denied_checks == 0)
      $fatal(1,"COVERAGE checks=%0d valid=%0d denied=%0d early=%0d",checks,valid_checks,denied_checks,early_payloads);
    $display("FP-HIGH-PAYLOAD-OK checks=%0d valid=%0d denied=%0d early=%0d",
             checks,valid_checks,denied_checks,early_payloads);
    $finish;
  end
endmodule
