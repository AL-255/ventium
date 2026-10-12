// Parent getters/normalization and old/new setup expressions are extracted by
// the runner from the pinned RTL. No full-engine temporal proof is implied.
integer count=0, fourstate=0, normalization=0;
integer min_exp=2147483647, max_exp=-2147483647;
logic [79:0] value;
logic [14:0] encoded;

task automatic check_exp(input logic [14:0] e, input logic [5:0] shift, input bit unknown_case);
  logic signed [31:0] old_value, new_value;
  old_value=reference_exp(e, shift);
  new_value=srt_div_input_exp(e, shift);
  if(old_value !== new_value)
    $fatal(1,"DIV_EXP_WIDTH_MISMATCH e=%h shift=%0d old=%h new=%h",e,shift,old_value,new_value);
  if(!unknown_case) begin
    if(new_value < min_exp) min_exp=new_value;
    if(new_value > max_exp) max_exp=new_value;
  end else fourstate++;
  count++;
endtask

task automatic check_operand(input logic [79:0] a);
  logic [191:0] before_value, after_value;
  before_value=reference_operand(a,~a);
  after_value=candidate_operand(a,~a);
  if(before_value !== after_value)
    $fatal(1,"DIV_EXP_WIDTH_OPERAND_MISMATCH a=%h old=%h new=%h",a,before_value,after_value);
  normalization++;
endtask

initial begin
  for(integer e=0;e<32768;e++)
    for(integer shift=0;shift<64;shift++) check_exp(15'(e),6'(shift),0);
  // Unknown exponent arithmetic must retain the original four-state result.
  for(integer bitpos=0;bitpos<15;bitpos++) begin
    for(integer fill=0;fill<2;fill++) begin
      for(integer shift=0;shift<64;shift++) begin
        encoded=fill ? 15'h7fff : 15'd0; encoded[bitpos]=1'bx;
        check_exp(encoded,6'(shift),1);
        encoded[bitpos]=1'bz; check_exp(encoded,6'(shift),1);
      end
    end
  end
  for(integer shift=0;shift<64;shift++) begin
    check_exp(15'bx,6'(shift),1); check_exp(15'bz,6'(shift),1);
  end
  // Source-linked old/new normalization statements, including zero mantissas,
  // every leading-one position and X/Z as in the parent's procedural CLZ.
  for(integer e=0;e<32768;e+=31) begin
    check_operand({1'b0,15'(e),64'd0});
    check_operand({1'b1,15'(e),64'hffffffffffffffff});
    for(integer bitpos=0;bitpos<64;bitpos++) begin
      check_operand({1'b0,15'(e),64'd1<<bitpos});
      check_operand({1'b1,15'(e),(64'd1<<bitpos)|((64'd1<<bitpos)-64'd1)});
    end
  end
  for(integer bitpos=0;bitpos<64;bitpos++) begin
    value={1'b0,15'd1,64'd0}; value[bitpos]=1'bx; check_operand(value);
    value[bitpos]=1'bz; check_operand(value);
    value={1'b1,15'h7ffe,64'hffffffffffffffff}; value[bitpos]=1'bx; check_operand(value);
    value[bitpos]=1'bz; check_operand(value);
  end
  if(count!=2101120 || fourstate!=3968 || normalization!=137796 || min_exp!=-16445 || max_exp!=16384)
    $fatal(1,"DIV_EXP_WIDTH_VACUOUS count=%0d fourstate=%0d normalization=%0d min=%0d max=%0d",
           count,fourstate,normalization,min_exp,max_exp);
  $display("DIV-EXP-WIDTH-OK count=%0d fourstate=%0d normalization=%0d min=%0d max=%0d",
           count,fourstate,normalization,min_exp,max_exp);
  $finish;
end
