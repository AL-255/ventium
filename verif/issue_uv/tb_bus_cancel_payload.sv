`default_nettype none
module tb_bus_cancel_payload;
  logic [15:0] controls=0;
  logic [31:0] raw_addr=0, raw_data=0, linear=0, translated_d=0, translated_i=0;
  logic [3:0] raw_strb=0;
  logic old_req, old_we, old_pre, new_req, new_we, new_pre;
  logic [31:0] old_addr, old_data, old_addr_pre, new_addr, new_data, new_addr_pre;
  logic [3:0] old_strb,new_strb;
  integer checked=0, accepted=0, cancelled=0, inactive_changes=0, unknown_cases=0;
  integer seed, unused_seed;
  bus_cancel_control old_dut(.controls,.raw_addr,.raw_data,.raw_strb,.linear,.translated_d,.translated_i,
    .bd_req(old_req),.bd_we(old_we),.bd_addr(old_addr),.bd_wdata(old_data),.bd_wstrb(old_strb),
    .mem_req_pre_sq(old_pre),.mem_addr_pre(old_addr_pre));
  bus_cancel_candidate new_dut(.controls,.raw_addr,.raw_data,.raw_strb,.linear,.translated_d,.translated_i,
    .bd_req(new_req),.bd_we(new_we),.bd_addr(new_addr),.bd_wdata(new_data),.bd_wstrb(new_strb),
    .mem_req_pre_sq(new_pre),.mem_addr_pre(new_addr_pre));

  task automatic check(input bit fourstate);
    #1;
    if({old_req,old_pre,old_addr_pre} !== {new_req,new_pre,new_addr_pre})
      $fatal(1,"BUS_CANCEL_CONTROL_MISMATCH sample=%0d controls=%h",checked,controls);
    if(new_req === 1'b1) begin
      if({old_we,old_addr,old_data,old_strb} !== {new_we,new_addr,new_data,new_strb})
        $fatal(1,"BUS_CANCEL_PAYLOAD_MISMATCH sample=%0d controls=%h",checked,controls);
      accepted++;
    end else if(new_req === 1'b0) begin
      cancelled++;
      if({old_we,old_addr,old_data,old_strb} !== {new_we,new_addr,new_data,new_strb})
        inactive_changes++;
    end
    checked++;
    if(fourstate) unknown_cases++;
  endtask

  initial begin
    seed=32'h20011011; unused_seed=$urandom(seed);
    for(integer c=0;c<65536;c++) for(integer p=0;p<8;p++) begin
      controls=16'(c);
      case(p)
        0: raw_addr=0;
        1: raw_addr=32'hffffffff;
        2: raw_addr=32'h00100fff;
        3: raw_addr=32'h000fffff;
        4: raw_addr=32'hfffe0000;
        5: raw_addr=32'haaaaaaaa;
        6: raw_addr=32'h55555555;
        default: raw_addr=$urandom;
      endcase
      linear=raw_addr^32'h12345678;
      raw_data=$urandom; raw_strb=4'(c+p);
      translated_d=$urandom; translated_i=$urandom;
      check(0);
    end
    for(integer i=0;i<8192;i++) begin
      controls=16'($urandom);
      if(i[0]) controls[(i/2)%16]=1'bx;
      else controls[(i/2)%16]=1'bz;
      raw_addr=$urandom; raw_addr[(i/32)%32]=1'bx;
      linear=$urandom; linear[(i/128)%32]=1'bz;
      raw_data=$urandom; raw_data[(i/256)%32]=1'bx;
      translated_i=$urandom; translated_d=$urandom;
      raw_strb=4'($urandom); raw_strb[(i/512)%4]=1'bz;
      check(1);
    end
    if(checked!=532480 || unknown_cases!=8192 || accepted<1000 ||
       cancelled<100000 || inactive_changes<100000)
      $fatal(1,"BUS_CANCEL_VACUOUS checked=%0d accepted=%0d cancelled=%0d changes=%0d",
             checked,accepted,cancelled,inactive_changes);
    $display("BUS-CANCEL-PAYLOAD-OK checked=%0d accepted=%0d cancelled=%0d inactive_changes=%0d fourstate=%0d",
             checked,accepted,cancelled,inactive_changes,unknown_cases);
    $finish;
  end
endmodule
`default_nettype wire
