module tb_extent;
  /* FUNCTION */
  longint unsigned vectors = 0;
  logic [31:0] rng = 32'h93757a31;
  logic [31:0] off, bound, high;
  logic [32:0] end33;
  logic [7:0] count;
  task automatic check(input logic [31:0] a, b, input logic [7:0] n);
    logic [32:0] last;
    logic expected, actual;
    last = {1'b0,a} + {25'd0,n} - 33'd1;
    expected = last > {1'b0,b};
    actual = seg_extent_above(a,b,n);
    if (expected !== actual)
      $fatal(1,"SEG-EXTENT-MISMATCH off=%h bound=%h count=%h expected=%b actual=%b",a,b,n,expected,actual);
    vectors++;
  endtask
  function automatic logic [31:0] advance(input logic [31:0] x);
    logic [31:0] v;
    v = x ^ (x << 13); v = v ^ (v >> 17); v = v ^ (v << 5);
    return v;
  endfunction
  initial begin
    for (int h=0; h<6; h++) begin
      case (h)
        0: high=32'h00000000;
        1: high=32'h00000100;
        2: high=32'h0000ff00;
        3: high=32'h00ffff00;
        4: high=32'hfffffe00;
        default: high=32'hffffff00;
      endcase
      for (int low=0; low<256; low++) begin
        for (int size=0; size<256; size++) begin
          off = high | 32'(low); count=8'(size);
          end33={1'b0,off}+{25'd0,count}-33'd1;
          check(off,32'd0,count);
          check(off,32'hffffffff,count);
          check(off,off,count);
          check(off,off+32'd255,count);
          check(off,end33[31:0],count);
          check(off,end33[31:0]-32'd1,count);
          check(off,end33[31:0]+32'd1,count);
        end
      end
    end
    for (int i=0; i<100000; i++) begin
      rng=advance(rng); off=rng;
      rng=advance(rng); bound=rng;
      rng=advance(rng); count=rng[7:0];
      check(off,bound,count);
    end
    $display("SEG-EXTENT-OK vectors=%0d",vectors);
    $finish;
  end
endmodule
