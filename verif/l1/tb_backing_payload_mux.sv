`timescale 1ns/1ps
module tb;
  localparam L1_IDLE=0,L1_FILL=1,L1_DONE=2,L1_BYP=3;
  reg [1:0] st;
  reg c_req,c_we,stream_path,bypass_q,byp_hi_beat,c_pair_req,c_pair_ready;
  reg c_pair_intent_ready;
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
  reg [31:0] random_q=32'h920ad35f;
  function automatic [31:0] next_random(input [31:0] value);
    reg [31:0] x;
    begin x=value^(value<<13);x=x^(x>>17);next_random=x^(x<<5);end
  endfunction
  integer checks=0,transactions=0,blocked=0,idle=0,fills=0,unknowns=0;
  task check;
    begin
      #1;
      if ({old_m_req,old_m_we,old_m_addr,old_m_wdata,old_m_wstrb,
           old_m_rd_narrow,old_m_rd_size,old_m_pair_req,old_m_pair_addr,
           old_m_pair_wdata,old_m_pair_wstrb} !==
          {new_m_req,new_m_we,new_m_addr,new_m_wdata,new_m_wstrb,
           new_m_rd_narrow,new_m_rd_size,new_m_pair_req,new_m_pair_addr,
           new_m_pair_wdata,new_m_pair_wstrb})
        $fatal(1,"BACKING-MUX-MISMATCH check=%0d st=%b req=%b we=%b stream=%b pair=%b ready=%b old_addr=%h new_addr=%h old_ws=%h new_ws=%h",
          checks,st,c_req,c_we,stream_path,c_pair_req,c_pair_intent_ready,
          old_m_addr,new_m_addr,old_m_wstrb,new_m_wstrb);
      if (new_m_req === 1'b1) transactions++;
      if (st==L1_IDLE && c_req && c_we && !stream_path &&
          c_pair_req && !c_pair_intent_ready) blocked++;
      if (c_req === 1'b0) idle++;
      if (st==L1_FILL) fills++;
      checks++;
    end
  endtask
  task set_controls(input [12:0] value);
    {st,c_req,c_we,stream_path,bypass_q,byp_hi_beat,c_pair_req,
     c_pair_ready,c_pair_intent_ready,fw}=value;
  endtask
  integer i,j,k,shape;
  reg [12:0] controls;
  initial begin
    for(i=0;i<64;i++) begin
      random_q=next_random(random_q);c_addr=random_q;
      random_q=next_random(random_q);c_wdata=random_q;
      random_q=next_random(random_q);c_pair_addr=random_q;
      random_q=next_random(random_q);c_pair_wdata=random_q;
      random_q=next_random(random_q);fbase=random_q;
      c_wstrb=i[3:0];c_pair_wstrb=~i[3:0];
      for(j=0;j<4;j++) begin
        byp_off_q[j]=3'(j+i);byp_siz_q[j]=2'(j+i);
      end
      for(shape=0;shape<8192;shape++) begin
        set_controls(13'(shape));check();
      end
    end
    // Directed four-state controls, not a claim of exhaustive 4-state proof.
    for(i=0;i<13;i++) for(j=0;j<4;j++) for(k=0;k<2;k++) begin
      controls=(j[0] ? 13'h1fff : 13'd0);
      controls[12:11]=2'(j);
      controls[i]=k ? 1'bz : 1'bx;
      set_controls(controls);check();unknowns++;
    end
    for(i=0;i<32;i++) for(j=0;j<4;j++) begin
      set_controls(13'h07f8);st=2'(j);
      c_addr=32'h01234567;c_pair_addr=32'h89abcdef;fbase=32'hffffffe0;
      c_addr[i]=1'bx;c_pair_addr[i]=1'bz;fbase[i]=1'bx;
      c_wstrb=4'bx101;c_pair_wstrb=4'b10z1;
      check();unknowns++;
    end
    if(transactions==0 || blocked==0 || idle==0 || fills==0 || unknowns!=232)
      $fatal(1,"BACKING-MUX-COVERAGE");
    $display("BACKING-MUX-OK checks=%0d transactions=%0d blocked=%0d idle=%0d fills=%0d four_state=%0d",
      checks,transactions,blocked,idle,fills,unknowns);
    $finish;
  end
endmodule
