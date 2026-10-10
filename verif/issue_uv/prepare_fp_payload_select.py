"""Default-off payload-only retiming preparation; never edits a live source.

S_PIPE is the only producer of direct register commands. Present that producer's
payload independently of the late admission predicate. Keep valid, ready,
retirement, faults, memory payload and asynchronous-owner classification intact.
No register, stage, extra command, or relaxed fast-path guard is introduced.
"""

FLAG = 'VEN_FP_PIPE_PAYLOAD_SELECT'
DECLARATION = '  logic fp_shared_pipe_cmd;'
PORTS = (
    '    .cmd_op(fp_shared_pipe_cmd ? fp_shared_direct_fxop : q_fxop),',
    '    .cmd_aluop(fp_shared_pipe_cmd ? pipe_u_eff.fp_aluop : q_f_aluop),',
    '    .cmd_sti(fp_shared_pipe_cmd ? pipe_u_eff.fp_sti : q_f_sti),',
    '    .cmd_pop(fp_shared_pipe_cmd ? fp_shared_direct_pop : q_f_pop),',
    '    .cmd_constant(fp_shared_pipe_cmd ? pipe_u_eff.fp_sti : q_f_const),',
    '    .cmd_update_fip(fp_shared_pipe_cmd || !fp_shared_admin),',
    '    .cmd_fip(fp_shared_pipe_cmd ? eip : q_pc), .cmd_fcs(arch_seg_sel(3\'(SG_CS))),',
    '    .cmd_update_fdp(!fp_shared_pipe_cmd && !fp_shared_admin && (q_f_mem_read || q_f_mem_write)),',
)
GUARDS = (
    '  assign pipe_fp_live_arm = (state == S_PIPE) && fsm_case_enabled &&',
    '  assign pipe_fp_fast_exec_ok = pipe_fp_live_arm && !(sys_mode && fp_dbg_active) &&',
    '                    && pipe_fp_fast_exec_ok && !fp_dbg_active',
    '  assign fp_shared_pipe_cmd = fp_shared_direct',
    '  assign fp_shared_load_cmd = cycle_mode && (state == S_FLOAD) &&',
    '  assign fp_shared_store_probe_cmd = cycle_mode && (state == S_FLOAD) &&',
    '      ((state == S_FEXEC) || fp_shared_pipe_cmd || fp_shared_load_cmd ||',
    '       fp_shared_store_probe_cmd);',
)


def transform(core):
    if FLAG in core or 'fp_shared_pipe_payload' in core:
        raise ValueError('payload selector already present')
    for anchor in (DECLARATION, *PORTS, *GUARDS):
        if core.count(anchor) != 1:
            raise ValueError('missing/ambiguous producer contract: ' + anchor)
    declaration = '''`ifdef VEN_FP_PIPE_PAYLOAD_SELECT
  // Payload ownership is known from registered state before late admission.
  // Every valid S_PIPE command necessarily has fp_shared_pipe_cmd asserted;
  // other valid producers are S_FEXEC/S_FLOAD and use the captured q_* fields.
  // In invalid cycles only payload/ready may change; acceptance stays gated.
  logic fp_shared_pipe_payload;
  assign fp_shared_pipe_payload = (state == S_PIPE);
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && fp_shared_cmd_valid &&
        (fp_shared_pipe_payload !== fp_shared_pipe_cmd))
      $fatal(1, "FP-PAYLOAD-OWNER: valid command changed producer");
  end
`endif
`endif
'''
    result = core.replace(DECLARATION, DECLARATION + '\n' + declaration)
    for port in PORTS:
        replacement = port.replace('fp_shared_pipe_cmd', 'fp_shared_pipe_payload')
        result = result.replace(port, '`ifdef ' + FLAG + '\n' + replacement +
                                '\n`else\n' + port + '\n`endif')
    return result
