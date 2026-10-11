`default_nettype none
module tb_fragment_read_payload;
  logic [22:0] controls = 0;
  logic [31:0] linear = 0, raw_addr = 0, raw_data = 0;
  logic [31:0] translated_d = 0, translated_i = 0, bus_data = 0, saved_data = 0, saved_low = 0;
  logic [3:0] raw_strb = 0, saved_strb = 0, size = 0;
  logic [2:0] first = 0;
  wire [10:0] old_control, new_control;
  wire [159:0] old_payload, new_payload;
  wire [3:0] old_strobes, new_strobes;
  integer checked=0, accepted=0, invalid_changes=0, fourstate=0, starts=0;
  integer seed, unused_seed;
  fragment_read_control before_dut(.controls, .linear, .raw_addr, .raw_data,
    .translated_d, .translated_i, .bus_data, .saved_data, .saved_low,
    .raw_strb, .saved_strb, .size, .first,
    .control_out(old_control), .payload_out(old_payload), .strobes_out(old_strobes));
  fragment_read_candidate after_dut(.controls, .linear, .raw_addr, .raw_data,
    .translated_d, .translated_i, .bus_data, .saved_data, .saved_low,
    .raw_strb, .saved_strb, .size, .first,
    .control_out(new_control), .payload_out(new_payload), .strobes_out(new_strobes));

  task automatic check(input bit unknown_payload);
    #1;
    if (old_control !== new_control || old_payload !== new_payload)
      $fatal(1, "FRAGMENT_CONTROL_MISMATCH sample=%0d controls=%h", checked, controls);
    if (new_control[0] === 1'b1) begin
      if (old_strobes !== new_strobes)
        $fatal(1, "FRAGMENT_PAYLOAD_MISMATCH sample=%0d controls=%h linear=%h size=%0d old=%h new=%h",
               checked, controls, linear, size, old_strobes, new_strobes);
      accepted++;
    end else if (old_strobes !== new_strobes) invalid_changes++;
    if (new_control[7] === 1'b1) starts++;
    checked++;
    if (unknown_payload) fourstate++;
  endtask

  task automatic random_payload;
    raw_addr=$urandom; raw_data=$urandom;
    translated_d=$urandom; translated_i=$urandom; bus_data=$urandom;
    saved_data=$urandom; saved_low=$urandom;
    raw_strb=4'($urandom); saved_strb=4'($urandom); first=3'($urandom);
  endtask

  initial begin
    seed=32'h20261011; unused_seed=$urandom(seed);
    for (integer st=0; st<16; st++)
    for (integer faults=0; faults<32; faults++)
    for (integer bytes=1; bytes<=4; bytes++)
    for (integer offset=0; offset<6; offset++)
    for (integer wr=0; wr<2; wr++)
    for (integer pg=0; pg<2; pg++)
    for (integer active=0; active<2; active++)
    for (integer aborting=0; aborting<2; aborting++) begin
      controls=23'($urandom);
      controls[3:0]=4'(st); controls[4]=1'(active); controls[8]=1'(aborting);
      controls[9]=1'(pg); controls[10]=1'b1; controls[11]=1'b1;
      controls[12]=1'(wr); controls[17:13]=5'(faults);
      // Include all physical/nonphysical states and both page-boundary sides.
      linear=32'h12345000 + ((offset < 4) ? 32'(4092+offset) : 32'(offset-4));
      size=4'(bytes); random_payload(); check(0);
    end
    // Admission controls stay binary. X/Z are placed in payload/address/size
    // state; this is not a claim of equivalence for unknown fault controls.
    for (integer n=0; n<8192; n++) begin
      controls=23'($urandom); random_payload(); linear=$urandom; size=4'($urandom);
      case (n%8)
        0: raw_strb[(n/8)%4]=1'bx;
        1: saved_strb[(n/8)%4]=1'bz;
        2: linear[(n/8)%32]=1'bx;
        3: first[(n/8)%3]=1'bz;
        4: size[(n/8)%4]=1'bx;
        5: saved_data[(n/8)%32]=1'bz;
        6: raw_data[(n/8)%32]=1'bx;
        7: bus_data[(n/8)%32]=1'bz;
      endcase
      check(1);
    end
    if (checked!=204800 || fourstate!=8192 || accepted<100 || invalid_changes<100 || starts<10)
      $fatal(1, "FRAGMENT_VACUOUS checked=%0d accepted=%0d invalid_changes=%0d starts=%0d",
             checked, accepted, invalid_changes, starts);
    $display("FRAGMENT-READ-PAYLOAD-OK checked=%0d accepted=%0d invalid_changes=%0d starts=%0d fourstate_payload=%0d",
             checked, accepted, invalid_changes, starts, fourstate);
    $finish;
  end
endmodule
`default_nettype wire
