// Independent ascending-search reference: each known-one overrides the
// previous index, yielding the same highest-one as the parent's break loop.
function automatic logic [5:0] reference_clz(input logic [63:0] x);
  logic [5:0] count;
  count=0;
  for(integer i=0;i<64;i++) if(x[i]) count=6'(63-i);
  return count;
endfunction
integer count=0, fourstate=0, seed, unused_seed;
logic [63:0] value;
task automatic check(input logic [63:0] x, input bit is_fourstate);
  if(reference_clz(x) !== srt_input_clz64(x))
    $fatal(1,"SRT_INPUT_HELPER_MISMATCH x=%h old=%0d new=%0d",
           x,reference_clz(x),srt_input_clz64(x));
  count++;
  if(is_fourstate) fourstate++;
endtask
initial begin
  seed=32'h19691011; unused_seed=$urandom(seed);
  check(64'd0,0); check(64'hffffffffffffffff,0);
  for(integer i=0;i<64;i++) begin
    check(64'd1<<i,0);
    check((64'd1<<i)|((64'd1<<i)-64'd1),0);
    check(~(64'd1<<i),0);
  end
  for(integer quarter=0;quarter<4;quarter++)
    for(integer i=0;i<65536;i++) check(64'(i)<<(quarter*16),0);
  for(integer i=0;i<100000;i++) begin
    value={$urandom,$urandom}; check(value>>(i%64),0);
  end
  // X/Z is not a known one. Exercise every position against a known one at
  // every other position, and no-known-one words (including all X/all Z).
  check(64'bx,1); check(64'bz,1);
  for(integer unknown=0;unknown<64;unknown++) begin
    value=0; value[unknown]=1'bx; check(value,1);
    value[unknown]=1'bz; check(value,1);
    for(integer known=0;known<64;known++) begin
      value='x; value[known]=1'b1; check(value,1);
      value='z; value[known]=1'b1; check(value,1);
      value=64'd1<<known; value[unknown]=1'bx; check(value,1);
      value[unknown]=1'bz; check(value,1);
    end
  end
  if(count!=378852 || fourstate!=16514)
    $fatal(1,"SRT_INPUT_HELPER_VACUOUS count=%0d fourstate=%0d",count,fourstate);
  $display("SRT-INPUT-HELPER-OK count=%0d fourstate=%0d",count,fourstate);
  $finish;
end
