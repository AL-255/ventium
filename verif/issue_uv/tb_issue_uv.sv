// Directed decoder + U/V-pairer regression for stack-pointer dependencies.
// A V pipe reads the pre-issue GPR file, so every U->V ESP RAW must be rejected;
// an ESP-only WAW intentionally remains pairable (its value is not consumed).
`timescale 1ns/1ps
module tb_issue_uv;
  import ventium_decode_pkg::*;

  logic [7:0] ub0, ub1, ub2, ub3, ub4, ub5;
  logic [7:0] vb0, vb1, vb2, vb3, vb4, vb5;
  fpd_t uop, vop;
  logic pair_ok;
  int failures = 0;

  decode u_decode (
    .ib0(ub0), .ib1(ub1), .ib2(ub2), .ib3(ub3), .ib4(ub4), .ib5(ub5),
    .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(uop)
  );
  decode v_decode (
    .ib0(vb0), .ib1(vb1), .ib2(vb2), .ib3(vb3), .ib4(vb4), .ib5(vb5),
    .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(vop)
  );
  issue_uv dut (.iu(uop), .iv(vop), .pair_ok(pair_ok));

  task automatic load_pair(
    input logic [7:0] a0, input logic [7:0] a1, input logic [7:0] a2,
    input logic [7:0] a3, input logic [7:0] a4, input logic [7:0] a5,
    input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2,
    input logic [7:0] b3, input logic [7:0] b4, input logic [7:0] b5
  );
    ub0=a0; ub1=a1; ub2=a2; ub3=a3; ub4=a4; ub5=a5;
    vb0=b0; vb1=b1; vb2=b2; vb3=b3; vb4=b4; vb5=b5;
  endtask

  task automatic expect_pair(input string name, input logic expected,
                             input logic expect_esp_raw);
    logic [7:0] esp_bit;
    begin
      esp_bit = 8'h10;
      #1;
      if (!uop.simple || !vop.simple) begin
        $display("FAIL %-28s decoder rejected u=%0d v=%0d", name, uop.simple, vop.simple);
        failures++;
      end else if (pair_ok !== expected) begin
        $display("FAIL %-28s pair=%0d expected=%0d u_r=%02x u_w=%02x v_r=%02x v_w=%02x",
                 name, pair_ok, expected, uop.reads, uop.writes, vop.reads, vop.writes);
        failures++;
      end else if (expect_esp_raw &&
                   ((uop.writes & esp_bit) == 0 || (vop.reads & esp_bit) == 0)) begin
        $display("FAIL %-28s ESP not represented: u_w=%02x v_r=%02x",
                 name, uop.writes, vop.reads);
        failures++;
      end else begin
        $display("ok   %-28s pair=%0d", name, pair_ok);
      end
    end
  endtask

  initial begin
    // Every producer reaches the current Quake class of stale ESP read.
    load_pair(8'h29,8'hc4,0,0,0,0, 8'h89,8'he7,0,0,0,0); // sub esp,eax; mov edi,esp
    expect_pair("SUB ESP,EAX -> MOV EDI,ESP", 1'b0, 1'b1);
    load_pair(8'h83,8'hec,8'h34,0,0,0, 8'h89,8'he0,0,0,0,0); // sub esp,0x34; mov eax,esp
    expect_pair("SUB ESP,imm8 -> MOV EAX,ESP", 1'b0, 1'b1);
    load_pair(8'h89,8'hc4,0,0,0,0, 8'h89,8'he7,0,0,0,0); // mov esp,eax; mov edi,esp
    expect_pair("MOV ESP,EAX -> MOV EDI,ESP", 1'b0, 1'b1);
    load_pair(8'h44,0,0,0,0,0, 8'h89,8'he7,0,0,0,0); // inc esp; mov edi,esp
    expect_pair("INC ESP -> MOV EDI,ESP", 1'b0, 1'b1);
    load_pair(8'hd1,8'he4,0,0,0,0, 8'h89,8'he7,0,0,0,0); // shl esp,1; mov edi,esp
    expect_pair("SHL ESP,1 -> MOV EDI,ESP", 1'b0, 1'b1);
    load_pair(8'h8b,8'h20,0,0,0,0, 8'h89,8'he7,0,0,0,0); // mov esp,[eax]; mov edi,esp
    expect_pair("LOAD ESP -> MOV EDI,ESP", 1'b0, 1'b1);

    // Preserve the narrow existing performance exception: this is ESP WAW only.
    load_pair(8'h89,8'hc4,0,0,0,0, 8'h89,8'hdc,0,0,0,0); // mov esp,eax; mov esp,ebx
    expect_pair("ESP WAW-only remains pairable", 1'b1, 1'b0);

    if (failures != 0) begin
      $display("ISSUE-UV-GATE-FAIL (%0d failure(s))", failures);
      $fatal(1);
    end
    $display("ISSUE-UV-GATE-OK");
    $finish;
  end
endmodule
