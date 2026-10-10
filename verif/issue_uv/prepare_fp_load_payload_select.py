"""Default-off early-load payload selection, without changing admission.

Only a complete S_FLOAD read can assert fp_shared_load_cmd. Present its data
before that late predicate. A valid first-beat m64 command necessarily owns
the checked wide response; a second-beat m64 command uses the captured low
word. Stores and all other states retain f_mem80. No stage or latency is added.
"""

FLAG = 'VEN_FP_LOAD_PAYLOAD_SELECT'
OLD = '''  assign fp_shared_cmd_mem = !fp_shared_load_cmd ? f_mem80 :
`ifdef VEN_FP_LOAD64
      fp_load64_take ? {f_mem80[79:64], bus_rdata_hi, mem_rdata} :
`endif
      (f_step == 4'd0 ? {f_mem80[79:32], mem_rdata} :
                       {f_mem80[79:64], mem_rdata, f_mem80[31:0]});'''
NEW = '''  // The command-valid logic still proves the complete, translated read.
  // Payload muxes need only registered producer/size/beat ownership. Neither
  // mem_ack nor fp_load64_take should precede FP conversion/normalization.
  assign fp_shared_cmd_mem =
      !((state == S_FLOAD) && q_f_mem_read && !q_f_mem_write) ? f_mem80 :
`ifdef VEN_FP_LOAD64
      ((q_f_mbytes == 4'd8) && (f_step == 4'd0)) ?
          {f_mem80[79:64], bus_rdata_hi, mem_rdata} :
`endif
      (f_step == 4'd0 ? {f_mem80[79:32], mem_rdata} :
                       {f_mem80[79:64], mem_rdata, f_mem80[31:0]});'''
GUARDS = (
    '  assign fp_shared_load_cmd = cycle_mode && (state == S_FLOAD) &&',
    '      q_f_mem_read && !q_f_mem_write && mem_ack && fsm_case_enabled &&',
    "      ((q_f_mbytes == 4'd4 && f_step == 4'd0) ||",
    "       (q_f_mbytes == 4'd8 && (f_step == 4'd1 || fp_load64_take))) &&",
    '  assign fp_load64_take = cycle_mode && (state == S_FLOAD) &&',
    "      q_f_mem_read && !q_f_mem_write && (q_f_mbytes == 4'd8) &&",
    "      (f_step == 4'd0) && fsm_case_enabled && mem_ack && bus_rdata_hi_valid &&",
    '      ((state == S_FEXEC) || fp_shared_pipe_cmd || fp_shared_load_cmd ||',
    '       fp_shared_store_probe_cmd);',
)


def transform(core):
    if FLAG in core or 'fp_shared_cmd_mem_reference' in core:
        raise ValueError('load payload selector already present')
    for anchor in (OLD, *GUARDS):
        if core.count(anchor) != 1:
            raise ValueError('missing/ambiguous source ownership: '+anchor)
    reference = OLD.replace('fp_shared_cmd_mem =', 'fp_shared_cmd_mem_reference =')
    checks = '''
`ifndef SYNTHESIS
  logic [79:0] fp_shared_cmd_mem_reference;
''' + reference + '''
  always_ff @(posedge clk) begin
    if (rst_n && fp_shared_cmd_valid &&
        (fp_shared_cmd_mem !== fp_shared_cmd_mem_reference))
      $fatal(1, "FP-LOAD-PAYLOAD-OWNER: valid command changed its operand");
  end
`endif'''
    return core.replace(OLD, '`ifdef '+FLAG+'\n'+NEW+checks+
                        '\n`else\n'+OLD+'\n`endif')
