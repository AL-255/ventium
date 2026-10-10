#!/usr/bin/env python3
"""Remove the integer-memory ACK cone from the live x87 admission qualifier.

Prepare only a fresh private candidate. The decoder invariant is a prerequisite,
not a timing exception: executable x87 descriptors have neither integer-memory
flag set, and an admitted integer packet must still exclude all live x87 arms.
"""
import argparse
import hashlib
from pathlib import Path

PARENT_SHA = '38e5f290d4888548cbe4f86f9f2f1ce7b3074b196f5b7039ce41900a93187dd7'
OLD = '''  assign pipe_fp_live_arm = (state == S_PIPE) && fsm_case_enabled &&
                            !pipe_mem_active_q && !fp_issue_block &&
                            exec_issue_ok && pipe_frontend_ready &&
                            (stall_cnt == 7'd0) && (pending_mem_pen == 7'd0) &&
                            !pipe_mem_wait;'''
NEW = '''  // All consumers additionally require pipe_u_eff.is_fp. The decoder
  // leaves both integer-memory flags clear for register x87 AND FK_MEM:
  // the latter only admits a descriptor; S_FLOAD issues its operand later.
  // With no admitted packet and neither live integer-memory flag, both
  // pipe_load_req and pipe_store_req are zero independently of mem_ack.
  // Express that cofactor directly, avoiding a cache/AXI-ACK path through
  // this otherwise memory-free FP command enable. Keep every fault, debug,
  // frontend, trap and outstanding-packet guard unchanged.
  assign pipe_fp_live_arm = (state == S_PIPE) && fsm_case_enabled &&
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
    if source.count(OLD) != 1:
        raise ValueError('live FP qualifier drift')
    return source.replace(OLD, NEW)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, out = args.source.resolve(strict=True), args.out.resolve()
    if not out.is_relative_to(scratch) or out == source:
        raise ValueError('candidate must be a fresh external scratch file')
    original = source.read_text()
    with out.open('x') as f:
        f.write(transform(original))
    assert source.read_text() == original


if __name__ == '__main__':
    main()
