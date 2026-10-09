// Actual candidate predicate is extracted by the runner. This is a capture-
// permit unit, not an I-cache implementation or a substitute for QEMU tests.
module tb_fp_short_window;
  typedef enum logic {S_PIPE, S_OTHER} state_t;
  state_t state;
  localparam int SG_CS=0;
  logic cycle_mode,def16,pipe_fetch_checked_handoff,d_unknown,d_is_x87;
  logic exec_issue_ok,icsnp_v1,icsnp_v2,ic_snoop_valid,sys_mode,real_mode,v86;
  logic [7:0] refdecode_ibuf[16];
  logic [3:0] d_len;
  logic [31:0] flin,eip,seg_limit[1];
  logic first_owner,last_owner;
  logic pipe_fp_short_window_ok;
  integer checks=0;
  function automatic logic ic_buffered(input logic [31:0] addr);
    return (addr==flin) ? first_owner : last_owner;
  endfunction
  `include "fp_short_equation.svh"
  task automatic defaults;
    state=S_PIPE;cycle_mode=1;def16=0;pipe_fetch_checked_handoff=0;
    d_unknown=0;d_is_x87=1;d_len=2;exec_issue_ok=1;
    icsnp_v1=0;icsnp_v2=0;ic_snoop_valid=0;sys_mode=1;real_mode=0;v86=0;
    flin=32'h100f0311;eip=32'hf0311;seg_limit[0]=32'hffffffff;
    first_owner=1;last_owner=1;
    for(int i=0;i<16;i++)refdecode_ibuf[i]=0;
    refdecode_ibuf[0]=8'hd9;
  endtask
  task automatic check(input logic expected);
    #1;
    if(pipe_fp_short_window_ok!==expected)
      $fatal(1,"FP-SHORT predicate got=%b expected=%b len=%d linear=%x eip=%x limit=%x",
             pipe_fp_short_window_ok,expected,d_len,flin,eip,seg_limit[0]);
    checks++;
  endtask
  initial begin
    for(int op=0;op<256;op++)begin
      defaults();refdecode_ibuf[0]=8'(op);check(op>=216 && op<=223);
    end
    for(int len=0;len<16;len++)begin
      defaults();d_len=4'(len);check(len>=2 && len<=7);
    end
    for(int blocker=0;blocker<14;blocker++)begin
      defaults();
      case(blocker)
        0:state=S_OTHER;
        1:cycle_mode=0;
        2:def16=1;
        3:pipe_fetch_checked_handoff=1;
        4:d_unknown=1;
        5:d_is_x87=0;
        6:exec_issue_ok=0;
        7:icsnp_v1=1;
        8:icsnp_v2=1;
        9:ic_snoop_valid=1;
        10:real_mode=1;
        11:v86=1;
        12:first_owner=0;
        13:last_owner=0;
        default:;
      endcase
      check(0);
    end
    for(int len=2;len<=7;len++)
      for(int tail=0;tail<17;tail++)begin
        defaults();d_len=4'(len);flin=32'h100f0fff-32'(tail);
        check(len<=tail+1);
        defaults();d_len=4'(len);seg_limit[0]=eip+32'(tail);
        check(len<=tail+1);
      end
    defaults();eip=32'hffffffff;flin=32'h0fff;check(0);
    defaults();sys_mode=0;real_mode=1;v86=1;seg_limit[0]=0;check(1);
    $display("FP-SHORT-PREDICATE-OK checks=%0d",checks);
    $finish;
  end
endmodule
