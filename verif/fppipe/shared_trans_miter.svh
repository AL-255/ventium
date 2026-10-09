// Test-only, included in the existing independent-arithmetic trans fixture.
// Unmodified control shares real ALU/divider replies with the candidate. Match
// all outputs at every edge, not just final rounded values or total latency.
  logic control_fx_req, control_div_start, control_busy, control_done;
  logic control_c2, control_ie, control_pe;
  logic [1:0] control_fx_op, control_fx_rc, control_fx_pc, control_div_rc;
  logic [79:0] control_fx_a, control_fx_b, control_div_a, control_div_b;
  logic [79:0] control_primary, control_secondary;
  int unsigned miter_clocks = 0;
  int unsigned pack_uses [0:5] = '{default:0};
  ven_fp_trans_control unchanged (
    .clk(clk), .rst_n(rst_n), .start(start), .op(op), .x(x), .y(y), .rc(rc),
    .fx_req(control_fx_req), .fx_op(control_fx_op),
    .fx_a(control_fx_a), .fx_b(control_fx_b),
    .fx_rc(control_fx_rc), .fx_pc(control_fx_pc),
    .fx_vld(dut_fx_vld), .fx_result(dut_fx_result), .fx_pe(dut_fx_pe),
    .divide_start(control_div_start), .divide_a(control_div_a), .divide_b(control_div_b),
    .divide_rc(control_div_rc), .divide_done(dut_div_done),
    .divide_result(dut_div_result[79:0]), .busy(control_busy), .done(control_done),
    .primary(control_primary), .secondary(control_secondary),
    .flag_c2(control_c2), .flag_ie(control_ie), .flag_pe(control_pe)
  );
  always @(posedge clk) begin
    if (rst_n) begin
      case (dut.state)
        dut.T_F2_PACK: pack_uses[0]++;
        dut.T_ATAN_SPLIT: pack_uses[1]++;
        dut.T_ATAN_PACK: pack_uses[2]++;
        dut.T_FY_PACK: pack_uses[3]++;
        dut.T_WIDE_RESULT: if (dut.wide_issued_q && dut.wide_done) begin
          if (dut.wide_cont_q == dut.WIDE_FY_T2) pack_uses[4]++;
          if (dut.wide_cont_q == dut.WIDE_ATAN_Z2) pack_uses[5]++;
        end
        default: ;
      endcase
    end
    #1;
    if ({dut_fx_req, dut_fx_op, dut_fx_a, dut_fx_b, dut_fx_rc, dut_fx_pc,
         dut_div_start, dut_div_a, dut_div_b, dut_div_rc, new_busy, new_done,
         new_primary, new_secondary, new_c2, new_ie, new_pe} !==
        {control_fx_req, control_fx_op, control_fx_a, control_fx_b, control_fx_rc,
         control_fx_pc, control_div_start, control_div_a, control_div_b,
         control_div_rc, control_busy, control_done, control_primary,
         control_secondary, control_c2, control_ie, control_pe})
      $fatal(1, "TRANS-PACK edge output mismatch clock=%0d", miter_clocks);
    if ({dut.state, dut.at_table_index_q, dut.fy_t2_q, dut.at_z2_q} !==
        {unchanged.state, unchanged.at_table_index_q, unchanged.fy_t2_q, unchanged.at_z2_q})
      $fatal(1, "TRANS-PACK internal consumer mismatch clock=%0d", miter_clocks);
    miter_clocks++;
  end
  final begin
    for (int i=0; i<6; i++)
      assert (pack_uses[i] > 0) else $fatal(1, "unexercised pack consumer %0d", i);
    $display("TRANS-PACK-EDGE-AB-OK clocks=%0d uses=%p", miter_clocks, pack_uses);
  end
