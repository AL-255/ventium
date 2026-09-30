// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Real production IDE port protocol. No forced state or replacement IDE FSM.
`timescale 1ns/1ps
module tb_ide_pio_irq;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic irq, drq, no_data, io_wait, dbg_disable_irq, dbg_sw_reset;
  logic [1:0] drive_en;
  logic [2:0] request;
  logic [3:0] io_address=0, mgmt_address=0;
  logic io_read=0, io_write=0, io_32=0, mgmt_write=0, mgmt_read=0;
  logic [31:0] io_writedata=0, io_readdata;
  logic [15:0] mgmt_writedata=0, mgmt_readdata;
  int checks=0, control_errors=0, irq_errors=0;
  int irq_edges;
  logic previous_irq;
  ide dut(.clk(clk), .rst_n(rst_n), .irq(irq), .drq(drq),
          .dbg_disable_irq(dbg_disable_irq), .dbg_sw_reset(dbg_sw_reset),
          .use_fast(1'b1), .no_data(no_data), .drive_en(drive_en),
          .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
          .io_write(io_write), .io_writedata(io_writedata), .io_32(io_32),
          .io_wait(io_wait), .request(request), .mgmt_address(mgmt_address),
          .mgmt_write(mgmt_write), .mgmt_writedata(mgmt_writedata),
          .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata));

  always @(negedge clk) begin
    if (!rst_n) begin irq_edges=0; previous_irq=0; end
    else begin
      if (irq && !previous_irq) irq_edges++;
      previous_irq=irq;
    end
  end
  task automatic idle(input int count=3);
    repeat(count) begin @(negedge clk); #1; end
  endtask
  task automatic check(input string label, input bit condition);
    checks++;
    if (!condition) begin control_errors++; $display("IDE-CONTROL-FAIL %s",label); end
  endtask
  task automatic read_irq_check(input string label, input bit condition);
    checks++;
    if (!condition) begin
      irq_errors++;
      $display("IDE-READ-EXTRA-IRQ %s irq=%0b edges=%0d status=%02x count=%0d request=%0d",
               label,irq,irq_edges,dut.status,dut.io_cnt,request);
    end
  endtask
  function automatic logic [15:0] pattern(input int seed,input int index);
    return 16'(seed ^ index);
  endfunction
  task automatic host_write(input logic[3:0] address,input logic[15:0] value);
    @(negedge clk); #1; mgmt_address=address;mgmt_writedata=value;mgmt_write=1;
    @(negedge clk); #1; mgmt_write=0;
    idle(2);
  endtask
  task automatic host_read(input logic[3:0] address,output logic[15:0] value);
    @(negedge clk); #1;mgmt_address=address;mgmt_read=1;
    @(negedge clk); #1;value=mgmt_readdata;mgmt_read=0;
    idle(2);
  endtask
  task automatic guest_write(input logic[3:0] address,input logic[15:0] value);
    @(negedge clk); #1;io_address=address;io_writedata={16'd0,value};io_write=1;
    @(negedge clk); #1;io_write=0;
    idle(2);
  endtask
  task automatic guest_read(input logic[3:0] address,output logic[15:0] value);
    @(negedge clk); #1;io_address=address;io_read=1;
    @(negedge clk); #1;value=io_readdata[15:0];io_read=0;
    idle(2);
  endtask
  task automatic reset_device;
    rst_n=0;io_read=0;io_write=0;mgmt_read=0;mgmt_write=0;
    idle(5);rst_n=1;idle(5);
    // Word 6: update master presence, no HOB, leave use_wait=0.
    host_write(6,16'h0009);
    host_write(0,16'h0000);host_write(5,16'h50e0);
    check("reset-published-ready",drive_en==1 && request==0 && !irq && !drq);
  endtask
  task automatic descriptor(input logic[7:0] status,input int seed,input bit fill);
    // Actual ide_set_regs words; word 5 owns descriptor publication.
    host_write(0,16'h0001); // One 512-byte block: 256 guest 16-bit PIO words.
    host_write(1,16'h0100);host_write(2,0);host_write(3,0);host_write(4,0);
    if (fill) for(int i=0;i<256;i++) host_write(15,pattern(seed,i));
    host_write(5,{status,8'he0});
    check("descriptor-size",dut.blk_size==256 && dut.io_cnt==0 && request==0);
  endtask
  task automatic drain(input int seed);
    logic[15:0] got;
    for(int i=0;i<256;i++) begin
      guest_read(0,got);
      check($sformatf("read-word-%0d",i),got==pattern(seed,i));
    end
    idle(5);
    check("drain-count",dut.io_cnt==256 && !drq && !dut.block_done_pending);
  endtask
  task automatic push(input int seed);
    for(int i=0;i<256;i++) guest_write(0,pattern(seed,i));
    idle(5);
    check("push-completion",dut.io_cnt==256 && !drq && request==5 && !irq);
  endtask
  task automatic receive(input int seed);
    logic[15:0] got;
    // A nonbuffer management access resets the cursor, as ide_get_regs followed
    // by ide_recvbuf does. Readback is through the real word-F data port.
    host_read(0,got);
    for(int i=0;i<256;i++) begin
      host_read(15,got);
      check($sformatf("write-word-%0d",i),got==pattern(seed,i));
    end
  endtask
  task automatic coincident_status_publication;
    // Real one-clock port strobes, not a forced completion record. The newly
    // published event wins a same-clock regular-status acknowledgement.
    @(negedge clk); #1;
    io_address=7;io_read=1;
    mgmt_address=5;mgmt_writedata=16'h54e0;mgmt_write=1;
    @(negedge clk); #1;io_read=0;mgmt_write=0;
    idle(3);
  endtask
  initial begin
    logic[15:0] status;
    // 1: Final READ SECTORS block. Acknowledge data-ready IRQ before PIO drain.
    reset_device();guest_write(7,16'h0020);descriptor(8'h5e,'hA500,1);
    check("read-ready-one-irq",irq && irq_edges==1 && drq && dut.status==8'h58);
    guest_read(7,status);
    check("regular-status-acks",status==16'h0058 && !irq);
    drain('hA500);
    check("read-terminal-status",dut.status==8'h50 && request==0);
    read_irq_check("single-read-no-second-completion-irq",!irq && irq_edges==1);

    // 2: Alternate status must not clear the original held data-ready IRQ.
    reset_device();guest_write(7,16'h0020);descriptor(8'h5e,'hB500,1);
    guest_read(14,status);
    check("alternate-status-does-not-ack",status==16'h0058 && irq && irq_edges==1);
    drain('hB500);
    check("held-read-irq-not-an-extra-edge",irq && irq_edges==1 && request==0);
    guest_read(14,status);check("terminal-alternate-status",status==16'h0050 && irq);
    guest_read(7,status);check("terminal-status-ack",status==16'h0050 && !irq);

    // 3: Establishing nIEN before the command suppresses both read IRQ points.
    // This does not qualify masked-pending IRQ re-enable semantics.
    reset_device();guest_write(14,16'h0002);guest_write(7,16'h0020);
    descriptor(8'h5e,'hC500,1);drain('hC500);
    check("masked-read",dbg_disable_irq && !irq && irq_edges==0 && request==0);

    // 4: Two READ blocks: nonterminal drain requests the next block.
    reset_device();guest_write(7,16'h0020);descriptor(8'h5c,'hD500,1);
    guest_read(7,status);drain('hD500);
    check("nonterminal-read",dut.status==8'h80 && request==5 && !irq && irq_edges==1);
    descriptor(8'h5e,'hE500,1);guest_read(7,status);drain('hE500);
    check("multi-read-terminal",dut.status==8'h50 && request==0);
    read_irq_check("multi-read-one-irq-per-block",!irq && irq_edges==2);

    // 5: WRITE starts with DRQ but no IRQ. The host reads actual written data
    // before publishing completion. No backing file is substituted or invoked.
    reset_device();guest_write(7,16'h0030);descriptor(8'h58,'h0000,0);
    check("write-initial-drq-no-irq",drq && !irq && irq_edges==0);
    push('hF500);receive('hF500);
    descriptor(8'h54,'h0000,0);
    check("write-final-completion-irq",irq && irq_edges==1 && !drq && dut.status==8'h50 && request==0);
    guest_read(14,status);check("write-alt-status-retains-irq",status==16'h0050 && irq);
    guest_read(7,status);check("write-status-ack",status==16'h0050 && !irq);

    // 6: READ MULTIPLE uses the same descriptor contract, two final blocks.
    reset_device();guest_write(7,16'h00c4);descriptor(8'h5c,'h9500,1);
    guest_read(7,status);drain('h9500);
    check("read-multiple-next",request==5 && !irq && irq_edges==1);
    descriptor(8'h5e,'h9600,1);guest_read(7,status);drain('h9600);
    check("read-multiple-terminal",dut.status==8'h50 && request==0);
    read_irq_check("read-multiple-no-second-final-irq",!irq && irq_edges==2);

    // 7: IDENTIFY is another data-in terminal descriptor, not a backend write.
    reset_device();guest_write(7,16'h00ec);descriptor(8'h5e,'h9700,1);
    guest_read(7,status);drain('h9700);
    check("identify-terminal",dut.status==8'h50 && request==0);
    read_irq_check("identify-no-second-final-irq",!irq && irq_edges==1);

    // 8: Nondata GOOD and ERR results own their IRQ through word 5 publication.
    reset_device();guest_write(7,16'h0040);host_write(0,16'h0000);
    host_write(5,16'h54e0);
    check("nondata-ready-irq",dut.status==8'h50 && !drq && request==0 && irq && irq_edges==1);
    guest_read(7,status);check("nondata-status-ack",status==16'h0050 && !irq);
    guest_write(7,16'h0040);host_write(0,16'h0400);host_write(5,16'h55e0);
    check("nondata-error-irq",dut.status==8'h51 && dut.error==4 && !drq && request==0 && irq && irq_edges==2);
    guest_read(7,status);check("error-status-ack",status==16'h0051 && !irq);

    // 9: Word 5 IRQ publication retains priority over a same-clock status read.
    reset_device();guest_write(7,16'h0040);host_write(0,16'h0000);
    coincident_status_publication();
    check("publication-wins-status-read",dut.status==8'h50 && irq && irq_edges==1 && request==0);
    guest_read(7,status);check("later-status-read-acks-publication",!irq && status==16'h0050);

    // 10: A new command after terminal drain clears the preceding held IRQ.
    reset_device();guest_write(7,16'h0020);descriptor(8'h5e,'h9800,1);drain('h9800);
    check("new-command-prior-held-irq",irq && irq_edges==1);
    guest_write(7,16'h0030);
    check("new-command-after-drain",!irq && dut.status==8'h80 && request==4 && !dut.block_done_pending);

    // 11: Device reset withdraws an outstanding published event.
    reset_device();host_write(5,16'h54e0);
    check("reset-prior-irq",irq);
    rst_n=0;idle(4);
    check("reset-clears-irq",!irq && !drq && request==6 && dut.status==8'h80 && !dut.block_done_pending);
    rst_n=1;idle(3);
    $display("IDE-PIO-IRQ-RESULT checks=%0d irq_errors=%0d control_errors=%0d",checks,irq_errors,control_errors);
    if(control_errors) $fatal(1,"IDE-PIO-IRQ-CONTROL-FAIL");
    if(irq_errors) $fatal(1,"IDE-PIO-IRQ-READ-RED");
    $display("IDE-PIO-IRQ-GATE-OK");$finish;
  end
endmodule
