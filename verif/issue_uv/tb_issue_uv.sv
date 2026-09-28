// Directed decoder + U/V-pairer regression for stack-pointer dependencies and
// P5's displacement-plus-immediate pairing restriction.  A V pipe reads the
// pre-issue GPR file, so every U->V ESP RAW must be rejected; an ESP-only WAW
// intentionally remains pairable (its value is not consumed).
`timescale 1ns/1ps
module tb_issue_uv;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;

  logic [7:0] ub0, ub1, ub2, ub3, ub4, ub5, ub6;
  logic [7:0] vb0, vb1, vb2, vb3, vb4, vb5, vb6;
  fpd_t uop, vop, uop_def16;
  logic pair_ok;
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
  logic pair_mem_ok;
`endif
  int failures = 0;

  decode u_decode (
    .ib0(ub0), .ib1(ub1), .ib2(ub2), .ib3(ub3), .ib4(ub4), .ib5(ub5), .ib6(ub6),
    .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(uop)
  );
  decode v_decode (
    .ib0(vb0), .ib1(vb1), .ib2(vb2), .ib3(vb3), .ib4(vb4), .ib5(vb5), .ib6(vb6),
    .iflags(32'h2), .def16(1'b0), .cycle_mode(1'b1), .uop(vop)
  );
  // The fast stack packet intentionally covers only the 32-bit operand form.
  // Drive the same bytes through a 16-bit-default decoder to prove it remains
  // fail-closed to the established slow stack machinery.
  decode u_decode_def16 (
    .ib0(ub0), .ib1(ub1), .ib2(ub2), .ib3(ub3), .ib4(ub4), .ib5(ub5), .ib6(ub6),
    .iflags(32'h2), .def16(1'b1), .cycle_mode(1'b1), .uop(uop_def16)
  );
`ifdef VEN_PERF_PROFILE
  logic [2:0] pair_reason;
`endif
  issue_uv dut (
      .iu(uop), .iv(vop), .pair_ok(pair_ok)
`ifdef VEN_P54_DUAL_READ_ALU_PAIR
    , .pair_mem_ok(pair_mem_ok)
`endif
`ifdef VEN_PERF_PROFILE
    , .pair_reason(pair_reason)
`endif
  );

  task automatic load_pair(
    input logic [7:0] a0, input logic [7:0] a1, input logic [7:0] a2,
    input logic [7:0] a3, input logic [7:0] a4, input logic [7:0] a5,
    input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2,
    input logic [7:0] b3, input logic [7:0] b4, input logic [7:0] b5
  );
    ub0=a0; ub1=a1; ub2=a2; ub3=a3; ub4=a4; ub5=a5; ub6=8'd0;
    vb0=b0; vb1=b1; vb2=b2; vb3=b3; vb4=b4; vb5=b5; vb6=8'd0;
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

`ifdef VEN_PERF_PROFILE
  // The production decision remains pair_ok.  Exercise each diagnostic
  // first-rejection bucket independently so a performance report cannot point
  // at the wrong restriction after future pairing-table edits.
  task automatic expect_pair_reason(input string name, input logic [2:0] expected);
    begin
      #1;
      if (pair_reason !== expected) begin
        $display("FAIL %-28s reason=%0d expected=%0d", name, pair_reason, expected);
        failures++;
      end else begin
        $display("ok   %-28s reason=%0d", name, pair_reason);
      end
    end
  endtask
`endif

  // The following V XOR is intentionally independent and V-pairable.  These
  // checks therefore prove the pairer is rejecting exactly `disp_imm`, rather
  // than a register hazard or a generic memory rule.
  task automatic expect_dispimm_pair(input string name, input logic want_dispimm,
                                     input logic want_pair);
    begin
      #1;
      if (!uop.simple || !uop.is_mem || !uop.mem_lhs || !uop.use_imm ||
          !vop.simple || !vop.pairs_second || uop.disp_imm !== want_dispimm ||
          pair_ok !== want_pair) begin
        $display("FAIL %-28s u(simple=%0d mem=%0d lhs=%0d imm=%0d dispimm=%0d) v(simple=%0d second=%0d) pair=%0d; want dispimm=%0d pair=%0d",
                 name, uop.simple, uop.is_mem, uop.mem_lhs, uop.use_imm,
                 uop.disp_imm, vop.simple, vop.pairs_second, pair_ok,
                 want_dispimm, want_pair);
        failures++;
      end else begin
        $display("ok   %-28s dispimm=%0d pair=%0d", name, uop.disp_imm, pair_ok);
      end
    end
  endtask

  task automatic expect_stack_forms;
    logic [7:0] rbit;
    begin
      // Check every opcode encoding, including PUSH ESP and POP ESP.  A simple
      // INC is supplied as the following candidate: first landing is U-only so
      // it must not pair even when the V instruction is otherwise independent.
      for (int r=0; r<8; r++) begin
        rbit = 8'h01 << r;
        load_pair(8'h50+r, 0,0,0,0,0, 8'h40,0,0,0,0,0);
        #1;
        if (!uop.simple || !uop.is_stack || !uop.is_mem || !uop.is_store ||
            uop.is_load || uop.wreg || !uop.mem_ss || uop.len!=4'd1 ||
            uop.src!=r[2:0] || uop.reads!=(rbit|8'h10) ||
            uop.writes!=8'h10 || uop.addr_mask!=8'h10 ||
            uop.pairs_first || uop.pairs_second || pair_ok || uop_def16.simple) begin
          $display("FAIL PUSH r32 decode r=%0d simple=%0d stack=%0d mem=%0d store=%0d load=%0d src=%0d reads=%02x writes=%02x addr=%02x pair=%0d def16=%0d",
                   r, uop.simple, uop.is_stack, uop.is_mem, uop.is_store,
                   uop.is_load, uop.src, uop.reads, uop.writes, uop.addr_mask,
                   pair_ok, uop_def16.simple);
          failures++;
        end else begin
          $display("ok   PUSH r32 decode r=%0d", r);
        end

        load_pair(8'h58+r, 0,0,0,0,0, 8'h40,0,0,0,0,0);
        #1;
        if (!uop.simple || !uop.is_stack || !uop.is_mem || uop.is_store ||
            !uop.is_load || !uop.wreg || !uop.mem_ss || uop.len!=4'd1 ||
            uop.dst!=r[2:0] || uop.reads!=8'h10 ||
            uop.writes!=(rbit|8'h10) || uop.addr_mask!=8'h10 ||
            uop.pairs_first || uop.pairs_second || pair_ok || uop_def16.simple) begin
          $display("FAIL POP r32 decode r=%0d simple=%0d stack=%0d mem=%0d store=%0d load=%0d dst=%0d reads=%02x writes=%02x addr=%02x pair=%0d def16=%0d",
                   r, uop.simple, uop.is_stack, uop.is_mem, uop.is_store,
                   uop.is_load, uop.dst, uop.reads, uop.writes, uop.addr_mask,
                   pair_ok, uop_def16.simple);
          failures++;
        end else begin
          $display("ok   POP r32 decode r=%0d", r);
        end
      end
    end
  endtask

  task automatic expect_memory_adc(input int length, input logic [7:0] address_reads);
    #1;
`ifdef VEN_FAST_MEM_ADC
    if (!uop.simple || !uop.is_mem || uop.is_load || uop.is_store || uop.mem_lhs ||
        uop.alu_op != 5'd2 || !uop.wflags || !uop.wreg || uop.dst != 0 ||
        uop.len != length || uop.addr_mask != address_reads ||
        uop.reads != (address_reads | 8'h01) || uop.writes != 8'h01 ||
        !uop.pairs_first || uop.pairs_second || !pair_ok || uop_def16.simple)
      $fatal(1, "checked ADC packet len=%0d addr=%02x", length, address_reads);
`else
    if (uop.simple || pair_ok)
      $fatal(1, "memory ADC must remain slow without opt-in");
`endif
  endtask

  task automatic expect_memory_adc_slow(input string name);
    #1;
    if (uop.simple || pair_ok || uop_def16.simple)
      $fatal(1, "excluded memory ADC admitted: %s", name);
  endtask

  initial begin
    expect_stack_forms();
    // Every admitted address shape reuses the checked ADD packet. V is an
    // independent INC, which must preserve the carry generated by U's ADC.
    load_pair(8'h13,8'h06,0,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(2, 8'h40);
    load_pair(8'h13,8'h46,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(3, 8'h40);
    load_pair(8'h13,8'h86,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(6, 8'h40);
    load_pair(8'h13,8'h05,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(6, 8'h00);
    load_pair(8'h13,8'h04,8'h76,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(3, 8'h40);
    load_pair(8'h13,8'h44,8'h76,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(4, 8'h40);
    load_pair(8'h13,8'h84,8'h76,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(7, 8'h40);

    // Keep the intentionally unaudited ESP destination on the slow path.
    load_pair(8'h13,8'h26,0,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP base");
    load_pair(8'h13,8'h66,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP base+disp8");
    load_pair(8'h13,8'ha6,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP base+disp32");
    load_pair(8'h13,8'h25,4,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP absolute");
    load_pair(8'h13,8'h24,8'h76,0,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP SIB");
    load_pair(8'h13,8'h64,8'h76,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP SIB+disp8");
    load_pair(8'h13,8'ha4,8'h76,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc_slow("ESP SIB+disp32");
    load_pair(8'h13,8'h04,8'h25,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(7, 8'h00);
    load_pair(8'h13,8'h04,8'h75,4,0,0, 8'h43,0,0,0,0,0);
    expect_memory_adc(7, 8'h40);
    for (int scale=0; scale<4; scale++) begin
      for (int index_reg=0; index_reg<8; index_reg++) begin
        load_pair(8'h13,8'h04,8'((scale<<6)|(index_reg<<3)|5),
                  8'h78,8'h56,8'h34, 8'h90,0,0,0,0,0);
        ub6=8'h12;
        expect_memory_adc(7, index_reg==4 ? 8'd0 : (8'b1<<index_reg));
`ifdef VEN_FAST_MEM_ADC
        if (uop.mem_base_en || uop.mem_ss ||
            uop.mem_index_en != (index_reg!=4) ||
            uop.mem_index != index_reg || uop.mem_scale != scale ||
            uop.mem_disp != 32'h12345678)
          $fatal(1, "no-base SIB metadata scale=%0d index=%0d", scale, index_reg);
`endif
      end
    end

    // The optional bypass must agree with the diagnostic RAW classification.
    // Test both V operand ports, a parent-register byte dependency, and the
    // separate address / partial-write paths which deliberately lack bypass.
    load_pair(8'h8b,8'h06,0,0,0,0, 8'h01,8'hc3,0,0,0,0); // mov eax,[esi]; add ebx,eax
`ifdef VEN_LOAD_USE_FORWARD
    expect_pair("load -> V source", 1'b1, 1'b0);
`ifdef VEN_PERF_PROFILE
    expect_pair_reason("forwarded RAW accepted", 3'd0);
`endif
`else
    expect_pair("load -> V source disabled", 1'b0, 1'b0);
`endif
    load_pair(8'h8b,8'h06,0,0,0,0, 8'h39,8'hd8,0,0,0,0); // mov eax,[esi]; cmp eax,ebx
`ifdef VEN_LOAD_USE_FORWARD
    expect_pair("load -> V destination read", 1'b1, 1'b0);
`else
    expect_pair("load -> V destination disabled", 1'b0, 1'b0);
`endif
    load_pair(8'h8a,8'h26,0,0,0,0, 8'h89,8'hc3,0,0,0,0); // mov ah,[esi]; mov ebx,eax
`ifdef VEN_LOAD_USE_FORWARD
    expect_pair("AH load -> parent read", 1'b1, 1'b0);
`else
    expect_pair("AH load -> parent disabled", 1'b0, 1'b0);
`endif
    load_pair(8'h8a,8'h26,0,0,0,0, 8'h88,8'hc8,0,0,0,0); // mov ah,[esi]; mov al,cl
    expect_pair("partial-parent WAW rejected", 1'b0, 1'b0);
    load_pair(8'h8b,8'h06,0,0,0,0, 8'h8d,8'h58,4,0,0,0); // mov eax,[esi]; lea ebx,[eax+4]
    expect_pair("load -> LEA rejected", 1'b0, 1'b0);
    load_pair(8'h8b,8'h06,0,0,0,0, 8'h8b,8'h18,0,0,0,0); // mov eax,[esi]; mov ebx,[eax]
    expect_pair("load -> V memory rejected", 1'b0, 1'b0);
    load_pair(8'h8b,8'h26,0,0,0,0, 8'h01,8'hc4,0,0,0,0); // mov esp,[esi]; add esp,eax
    expect_pair("load -> ESP RAW/WAW rejected", 1'b0, 1'b1);

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
`ifdef VEN_LOAD_USE_FORWARD
    // Ordinary MOV-to-ESP has exactly one destination, unlike POP's stack
    // update. Its value uses the same checked-load bypass as any other GPR.
    expect_pair("LOAD ESP -> MOV EDI,ESP", 1'b1, 1'b1);
`else
    expect_pair("LOAD ESP -> MOV EDI,ESP", 1'b0, 1'b1);
`endif

    // Quake's post-init Host_Frame path: the accumulator-immediate AND must
    // serialize its following CMP because V would otherwise compare stale EAX
    // (the `mov al,[esi]` before it leaves stale high bits live).
    load_pair(8'h25,8'hff,8'h00,8'h00,8'h00,0, 8'h39,8'hd0,0,0,0,0); // and eax,0xff; cmp eax,edx
    expect_pair("AND EAX,imm -> CMP EAX,EDX", 1'b0, 1'b0);

    // AP-500 §5.6.2: either instruction having both an addressing displacement
    // and an immediate is U-only for this issue clock.  All four cases use an
    // independent V XOR, so no other pairing restriction can explain the
    // outcome.  Keep non-displacement controls to prevent broad rejection of
    // fast memory-immediate forms.
    load_pair(8'h83,8'h78,8'h04,8'h01,0,0, 8'h31,8'hdb,0,0,0,0); // cmp [eax+4],1; xor ebx,ebx
    expect_dispimm_pair("CMP [EAX+disp8],imm8", 1'b1, 1'b0);
    load_pair(8'h83,8'h7c,8'h88,8'h04,8'h01,0, 8'h31,8'hdb,0,0,0,0); // cmp [eax+ecx*4+4],1; xor ebx,ebx
    expect_dispimm_pair("CMP SIB+disp8,imm8", 1'b1, 1'b0);
    load_pair(8'h83,8'h38,8'h01,0,0,0, 8'h31,8'hdb,0,0,0,0); // cmp [eax],1; xor ebx,ebx
    expect_dispimm_pair("CMP [EAX],imm8 control", 1'b0, 1'b1);
    load_pair(8'h83,8'h3c,8'h88,8'h01,0,0, 8'h31,8'hdb,0,0,0,0); // cmp [eax+ecx*4],1; xor ebx,ebx
    expect_dispimm_pair("CMP SIB,imm8 control", 1'b0, 1'b1);

`ifdef VEN_FAST_MEM_ADD7
    // The seven-byte mod=10 SIB+disp32 ADD is the generic form used by
    // streaming/checksum code.  Check its exact displacement byte order and
    // complete AGI/dependency metadata here, independently of the system-mode
    // segment/page admission gate.
    load_pair(8'h03,8'h84,8'h32,8'h78,8'h56,8'h34,
              8'h31,8'hdb,0,0,0,0); // add eax,[edx+esi+0x12345678]; xor ebx,ebx
    ub6 = 8'h12;
    #1;
    if (!uop.simple || !uop.is_mem || uop.is_store || uop.mem_lhs ||
        uop.len != 4'd7 || uop.alu_op != 4'd0 || !uop.wflags || !uop.wreg ||
        uop.dst != 3'd0 || uop.src != 3'd0 || uop.base != 3'd2 ||
        !uop.mem_base_en || uop.mem_ss || uop.mem_index != 3'd6 ||
        uop.mem_scale != 2'd0 || !uop.mem_index_en ||
        uop.mem_disp != 32'h12345678 || uop.reads != 8'h45 ||
        uop.writes != 8'h01 || uop.addr_mask != 8'h44 ||
        !uop.pairs_first || !uop.pairs_second || !pair_ok) begin
      $display("FAIL ADD SIB+disp32 fast decode simple=%0d mem=%0d len=%0d dst=%0d base=%0d idx=%0d scale=%0d disp=%08x reads=%02x writes=%02x addr=%02x pair=%0d",
               uop.simple, uop.is_mem, uop.len, uop.dst, uop.base, uop.mem_index,
               uop.mem_scale, uop.mem_disp, uop.reads, uop.writes, uop.addr_mask, pair_ok);
      failures++;
    end else begin
      $display("ok   ADD SIB+disp32 fast decode");
    end
`endif

    // Preserve the narrow existing performance exception: this is ESP WAW only.
    load_pair(8'h89,8'hc4,0,0,0,0, 8'h89,8'hdc,0,0,0,0); // mov esp,eax; mov esp,ebx
    expect_pair("ESP WAW-only remains pairable", 1'b1, 1'b0);

`ifdef VEN_P54_DUAL_READ_ALU_PAIR
    // The hot gameplay ADC reg,[mem] / ADD reg,[mem] pair is legal when the
    // two effective addresses are independent. A same-bank pair may need an
    // extra EX clock, but it must not be rejected by the decode/class table.
    load_pair(8'h13,8'h06,0,0,0,0, 8'h03,8'h56,8'h24,0,0,0);
    #1;
    if (!uop.simple || !vop.simple || !uop.is_mem || !vop.is_mem ||
        uop.alu_op != ALU_ADC || vop.alu_op != ALU_ADD ||
        !pair_mem_ok || pair_ok) begin
      $display("FAIL ADC/ADD read pair decode u_simple=%0d v_simple=%0d u_mem=%0d v_mem=%0d u_op=%0d v_op=%0d pair_mem=%0d",
               uop.simple,vop.simple,uop.is_mem,vop.is_mem,uop.alu_op,vop.alu_op,pair_mem_ok);
      failures++;
    end else $display("ok   ADC/ADD memory read pair class");
`endif

`ifdef VEN_PERF_PROFILE
    // One representative of every ordered rejection in issue_uv.  These are
    // a profiler contract, not an execution-path extension.
    load_pair(8'he8,0,0,0,0,0, 8'h31,8'hdb,0,0,0,0); // CALL rel32; XOR EBX,EBX
    expect_pair_reason("profile non-simple", 3'd1);
    load_pair(8'h50,0,0,0,0,0, 8'h40,0,0,0,0,0); // PUSH EAX; INC EAX
    expect_pair_reason("profile class", 3'd2);
    load_pair(8'h83,8'h78,8'h04,8'h01,0,0, 8'h31,8'hdb,0,0,0,0);
    expect_pair_reason("profile disp+imm", 3'd3);
    load_pair(8'h29,8'hc4,0,0,0,0, 8'h89,8'he7,0,0,0,0);
    expect_pair_reason("profile RAW", 3'd4);
    load_pair(8'h31,8'hdb,0,0,0,0, 8'h89,8'hcb,0,0,0,0); // xor ebx,ebx; mov ebx,ecx
    expect_pair_reason("profile non-ESP WAW", 3'd5);
    load_pair(8'h31,8'hdb,0,0,0,0, 8'h8b,8'h0a,0,0,0,0); // xor ebx,ebx; mov ecx,[edx]
    expect_pair_reason("profile V memory", 3'd6);
`endif

    // Direct packet witnesses: architectural differentials alone can pass
    // through the slow FSM and do not prove byte fast-path admission.
    for (int direction=0; direction<2; direction++) begin
      for (int dst=0; dst<8; dst++) begin
        for (int src=0; src<8; src++) begin
          load_pair(direction ? 8'h8a : 8'h88,
                    8'(192 + (direction ? dst*8+src : src*8+dst)),
                    0,0,0,0, 8'h90,0,0,0,0,0);
          #1;
          if (!uop.simple || !uop.w8 || !uop.wreg || uop.wflags ||
              uop.len != 2 || uop.dst != 3'(dst % 4) ||
              uop.src != 3'(src % 4) || uop.dst_hi8 != (dst >= 4) ||
              uop.src_hi8 != (src >= 4) ||
              uop.reads != (8'b1 << (src % 4)) ||
              uop.writes != (8'b1 << (dst % 4)) ||
              !uop_def16.simple || !uop_def16.w8 || !uop_def16.w16 ||
              uop_def16.dst != uop.dst || uop_def16.src != uop.src)
            $fatal(1, "byte MOV packet dir=%0d dst=%0d src=%0d", direction, dst, src);
        end
      end
    end
    for (int regnum=0; regnum<8; regnum++) begin
      // SIB base ESP must stay ESP even when data register encoding is AH.
      load_pair(8'h88, 8'(4+regnum*8), 8'h24,0,0,0,
                8'h8a, 8'(4+regnum*8), 8'h24,0,0,0);
      #1;
      if (!uop.simple || !uop.is_store || !uop.w8 || !uop.mem_ss ||
          uop.base != 4 || uop.addr_mask != 8'h10 ||
          uop.src != 3'(regnum % 4) || uop.src_hi8 != (regnum >= 4) ||
          uop.reads != (8'h10 | (8'b1 << (regnum % 4))) ||
          !vop.simple || !vop.is_load || !vop.w8 || !vop.mem_ss ||
          vop.base != 4 || vop.addr_mask != 8'h10 || vop.reads != 8'h10 ||
          vop.dst != 3'(regnum % 4) || vop.dst_hi8 != (regnum >= 4) ||
          vop.writes != (8'b1 << (regnum % 4)) || pair_ok || uop_def16.simple)
        $fatal(1, "byte MOV ESP memory packet reg=%0d", regnum);
    end
    $display("ok   byte MOV packets: 128 register forms, 16 ESP memory forms");

    if (failures != 0) begin
      $display("ISSUE-UV-GATE-FAIL (%0d failure(s))", failures);
      $fatal(1);
    end
    $display("ISSUE-UV-GATE-OK");
    $finish;
  end
endmodule
