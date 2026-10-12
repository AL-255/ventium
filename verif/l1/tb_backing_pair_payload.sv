`timescale 1ns/1ps
module tb;
  localparam L1_IDLE=0,L1_FILL=1,L1_DONE=2,L1_BYP=3;
  reg [1:0] st;
  reg c_req,c_we,stream_path,bypass_q,byp_hi_beat,c_pair_req,c_pair_ready;
  reg [31:0] c_addr,c_wdata,c_pair_addr,c_pair_wdata,fbase;
  reg [3:0] c_wstrb,c_pair_wstrb;
  reg [2:0] fw;
  reg [2:0] byp_off_q[4];
  reg [1:0] byp_siz_q[4];
  wire [2:0] fill_word=fbase[4:2]+fw;
  // EXTRACTED_EQUATIONS
`ifndef VEN_P54_DUAL_STORE_PAIR
  assign {old_m_pair_req,old_m_pair_addr,old_m_pair_wdata,old_m_pair_wstrb}=69'd0;
  assign {new_m_pair_req,new_m_pair_addr,new_m_pair_wdata,new_m_pair_wstrb}=69'd0;
`endif
  reg [31:0] random_q=32'h743bea29;
  function automatic [31:0] next_random(input [31:0] value);
    reg [31:0] x;
    begin x=value^(value<<13);x=x^(x>>17);next_random=x^(x<<5);end
  endfunction
  integer checks=0,transactions=0,credit_checks=0,blocked_credit=0,unqualified_changes=0;
  task check;
    begin
      #1;
      if ({old_m_req,old_m_we,old_m_wdata,old_m_rd_narrow,old_m_rd_size,
           old_m_pair_req,old_m_pair_addr,old_m_pair_wdata,old_m_pair_wstrb} !==
          {new_m_req,new_m_we,new_m_wdata,new_m_rd_narrow,new_m_rd_size,
           new_m_pair_req,new_m_pair_addr,new_m_pair_wdata,new_m_pair_wstrb})
        $fatal(1,"BACKING-PAYLOAD-MISMATCH control/data at check %0d",checks);
      if (new_m_req || (st==L1_IDLE && c_req && !stream_path &&
`ifdef VEN_P54_LOAD_STORE_PAIR
                       1'b1
`else
                       c_we
`endif
                      )) begin
        if ({old_m_addr,old_m_wstrb} !== {new_m_addr,new_m_wstrb})
          $fatal(1,"BACKING-PAYLOAD-MISMATCH transaction/credit at check %0d",checks);
        if (new_m_req) transactions=transactions+1;
        else begin credit_checks=credit_checks+1; if(c_pair_req) blocked_credit=blocked_credit+1;end
      end else if ({old_m_addr,old_m_wstrb} !== {new_m_addr,new_m_wstrb})
        unqualified_changes=unqualified_changes+1;
`ifdef VEN_P54_DUAL_STORE_PAIR
      // Enforce the intended structural cut as well as functional equivalence:
      // inactive requests must not zero the payload used for pair credit.
      if (st!=L1_FILL) begin
`ifdef VEN_P54_LOAD_STORE_PAIR
        if (!c_we) begin
          if ({new_m_addr,new_m_wstrb} !== {c_pair_addr,c_pair_wstrb})
            $fatal(1,"BACKING-PAYLOAD-MISMATCH early V payload");
        end else
`endif
        if ({new_m_addr,new_m_wstrb} !== {c_addr,c_wstrb})
          $fatal(1,"BACKING-PAYLOAD-MISMATCH early U payload");
      end
`endif
      checks=checks+1;
    end
  endtask
  integer i,j,shape;
  initial begin
    for(i=0;i<128;i=i+1) begin
      random_q=next_random(random_q);c_addr=random_q;
      random_q=next_random(random_q);c_wdata=random_q;
      random_q=next_random(random_q);c_pair_addr=random_q;
      random_q=next_random(random_q);c_pair_wdata=random_q;
      random_q=next_random(random_q);fbase=random_q;
      c_wstrb=i[3:0];c_pair_wstrb=~i[3:0];
      for(j=0;j<4;j=j+1) begin
        byp_off_q[j]=3'(j+i);byp_siz_q[j]=2'(j+i);
      end
      for(shape=0;shape<4096;shape=shape+1) begin
        {st,c_req,c_we,stream_path,bypass_q,byp_hi_beat,c_pair_req,c_pair_ready,fw}=shape[11:0];
        check();
      end
    end
    if(transactions==0)
      $fatal(1,"BACKING-PAYLOAD-COVERAGE");
`ifdef VEN_P54_DUAL_STORE_PAIR
    if(credit_checks==0 || blocked_credit==0 || unqualified_changes==0)
      $fatal(1,"BACKING-PAYLOAD-COVERAGE pair hints");
`else
    if(unqualified_changes!=0)
      $fatal(1,"BACKING-PAYLOAD-COVERAGE default profile changed");
`endif
    $display("BACKING-PAYLOAD-OK checks=%0d transactions=%0d credit=%0d blocked=%0d unqualified=%0d",checks,transactions,credit_checks,blocked_credit,unqualified_changes);
    $finish;
  end
endmodule
