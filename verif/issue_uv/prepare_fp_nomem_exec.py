#!/usr/bin/env python3
"""Cofactor only FP execution; preserve the shared integer lookahead permit.

The earlier live-arm experiment regressed CoreMark because the misleadingly
named pipe_fp_live_arm also qualifies AGI/reference operand priming. Its exact
definition must remain untouched. Only FP-qualified execution consumes the
new memory-free cofactor.
"""
import hashlib
from prepare_fp_nomem_arm import PARENT_SHA, OLD

FAST_OLD = 'assign pipe_fp_fast_exec_ok = pipe_fp_live_arm &&'
FAST_NEW = 'assign pipe_fp_fast_exec_ok = pipe_fp_nomem_arm &&'
INSERT = '''

  // pipe_fp_live_arm above is also the integer AGI/reference-prime permit.
  // Keep it byte-for-byte unchanged. Only FP-qualified execution may use
  // this cofactor: an x87 descriptor has no integer-memory request, and an
  // outstanding integer packet still blocks the live command completely.
  logic pipe_fp_nomem_arm;
  assign pipe_fp_nomem_arm = (state == S_PIPE) && fsm_case_enabled &&
                            !pipe_mem_active_q && !fp_issue_block &&
                            exec_issue_ok && pipe_frontend_ready &&
                            (stall_cnt == 7'd0) && (pending_mem_pen == 7'd0) &&
                            !u_d.is_mem && !u_d.is_store;
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (state == S_PIPE) && !pipe_mem_active_q &&
        exec_issue_ok && pipe_frontend_ready && u_d.is_fp) begin
      assert (!u_d.is_mem && !u_d.is_store && !u_d.simple)
        else $fatal(1, "live x87 descriptor acquired integer-memory ownership");
      assert (!pipe_mem_wait)
        else $fatal(1, "live x87 descriptor depends on integer-memory ACK");
    end
  end
`endif'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('not the source-qualified L1-capture core parent')
    if source.count(OLD) != 1 or source.count(FAST_OLD) != 1:
        raise ValueError('shared/FP admission predicate drift')
    return source.replace(OLD, OLD+INSERT).replace(FAST_OLD, FAST_NEW)
