// Actual source-extracted producer/output selectors, not a substitute decoder.
module tb;
  reg [4:0] d_fetch_need=0, sfetch_valid_q=0;
  reg [31:0] sfetch_demand_addr=0;
  reg sfetch_interior16=0;
  reg [2:0] sfetch_beat_size_q=0;
  // EXTRACTED_EQUATIONS
  integer checks=0;
  task automatic check;
    #1;
    checks++;
    if (old_size !== new_size)
      $fatal(1,"SFETCH-INTERIOR-MISMATCH addr=%h need=%d valid=%d interior=%b stage=%d old=%b new=%b",
          sfetch_demand_addr,d_fetch_need,sfetch_valid_q,sfetch_interior16,
          sfetch_beat_size_q,old_size,new_size);
  endtask
  initial begin
    // Every page offset, both selector arms, all registered size values.
    for (int a=0;a<4096;a++)
      for (int b=0;b<8;b++)
        for (int i=0;i<2;i++) begin
          sfetch_demand_addr=32'h12345000+a;
          d_fetch_need=5'(a);sfetch_valid_q=5'(a>>5);
          sfetch_beat_size_q=3'(b);sfetch_interior16=1'(i);check();
        end
    // Every decoder/valid count, both arms and every registered size at the
    // last eight offsets. Includes need<valid wrap, zero and invalid sizes.
    for (int a=4088;a<4096;a++)
      for (int n=0;n<32;n++)
        for (int v=0;v<32;v++)
          for (int b=0;b<8;b++)
            for (int i=0;i<2;i++) begin
              sfetch_demand_addr=32'habcde000+a;
              d_fetch_need=5'(n);sfetch_valid_q=5'(v);
              sfetch_beat_size_q=3'(b);sfetch_interior16=1'(i);check();
            end
    if(checks!=196608)$fatal(1,"SFETCH-INTERIOR-COVERAGE");
    $display("SFETCH-INTERIOR-COFACTOR-OK checks=%0d",checks);
    $finish;
  end
endmodule
