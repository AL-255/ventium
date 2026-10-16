// Appended to the exact existing real-iobus harness. No internal state writes.
  task automatic frame_tail(input logic [7:0] byte_value);
    bit parity;
    parity=1;
    for(int b=0;b<8;b++) begin parity^=byte_value[b]; wire_cell(byte_value[b]); end
    wire_cell(parity); wire_cell(1); dev_data=1; dev_clk=1; idle(128);
  endtask
  initial begin
    if($value$plusargs("scenario=%d",scenario)) begin end
    if($value$plusargs("half=%d",half_period)) begin end
    if($value$plusargs("wait=%d",wait_cycles)) begin end
    if($value$plusargs("translate=%d",translated)) begin end
    if(half_period<1600) $fatal(1,"LOSS-AUX-SKID-FRAME-TOO-SHORT");
    idle(32); rst_n=1; idle(10000);
    write_port(16'h64,8'h60); write_port(16'h60,translated?8'h43:8'h03); idle(32);
    // Start reception while capacity exists. Fill only via real port-60 ACKs
    // while the ordinary physical frame is in flight; do not seed the FIFO.
    if(!kclk || !kdata) $fatal(1,"LOSS-AUX-SKID-INHIBITED");
    wire_cell(0);
    if(dut.keyb_state!=10) $fatal(1,"LOSS-AUX-SKID-NOT-RECEIVING");
    fork
      frame_tail(8'h5a);
      begin
        for(int n=0;n<64;n++) begin write_port(16'h60,8'hf4); idle(8); end
        if(!dut.keyb_fifo_full || received!=0) $fatal(1,"LOSS-AUX-SKID-FULL-PRECONDITION");
      end
    join
    if(received!=1 || !dut.keyb_fifo_full) $fatal(1,"LOSS-AUX-SKID-NO-FRAME");
    if(scenario==4) begin
      // Ordinary AA must cancel the full FIFO, retained scan and stale OBF,
      // then produce exactly its own self-test reply. Next frame must work.
      write_port(16'h64,8'haa); idle(10000);
      expect_byte(0,8'h55);
      wire_byte(8'h5a); expect_byte(0,translated?8'h1c:8'h5a);
    end else begin
      if(scenario==5) begin
        // The retained byte owns its original translation. A later command
        // byte must not reinterpret it when FIFO room finally appears.
        write_port(16'h64,8'h60); write_port(16'h60,translated?8'h03:8'h43);
      end else if(scenario!=3) $fatal(1,"LOSS-AUX-SKID-BAD-SCENARIO");
      for(int n=0;n<64;n++) expect_byte(0,8'hfa);
      read_port(16'h64,status);
      if(!(status & 1)) $fatal(1,"LOSS-AUX-RX-SKID-LOST");
      expect_byte(0,translated?8'h1c:8'h5a);
    end
    idle(32); read_port(16'h64,status);
    if(status & 8'ha3 || !dut.keyb_fifo_empty || !dut.mouse_fifo_empty)
      $fatal(1,"LOSS-AUX-SKID-EXTRA-OR-ERROR status=%h",status);
    $display("LOSS-AUX-SKID-OK scenario=%0d half=%0d wait=%0d translate=%0d received=%0d cycles=%0d reads=%0d writes=%0d",
             scenario,half_period,wait_cycles,translated,received,cycles,reads,writes);
    $finish;
  end
endmodule
