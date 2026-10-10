#!/usr/bin/env python3
"""Private, default-off raw branch fallthrough resident-read proposal."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG = 'VEN_RAW_BRANCH_FALLTHROUGH_PRIME'
TARGET = 'rtl/core/core_mem_chain.svh'
LEAF = 'core_raw_branch_mov.svh'
HERE = Path(__file__).resolve().parent


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('missing/ambiguous raw branch anchor: '+before)
    return text.replace(before, after)


def transform(text):
    if FLAG in text:
        raise ValueError('raw branch fallthrough proposal already applied')
    anchor = '`include "core_raw_held_prime.svh"'
    text = once(text, anchor, anchor + '''
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "raw branch prime requires cache-only raw priming");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "raw branch prime requires returned I-cache byte ownership");
`endif
`include "core_raw_branch_mov.svh"
`endif
''')
    # Raw function only: the unrelated uop-cache implementation is untouched.
    start = text.index('  function automatic fpd_t mc_descriptor(')
    end = text.index('  endfunction', start) + len('  endfunction')
    raw = text[start:end]
    raw = once(raw, '    fpd_t d;', '''    fpd_t d;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
    fpd_t branch_d;
    logic [4:0] off;
`endif''')
    raw = once(raw, "      d = '0;", """      d = '0;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
      branch_d = '0;
      off = {1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len};
      // Consume at most three bytes of the ALREADY RETURNED frontend span.
      // No third full decoder, extra cache read port, fetch, or saved uop.
      // The first/last ownership checks include physical way and collision.
      if (mc_prime_v_branch && off <= 5'd13 &&
          pc == eip + {27'd0,off} && lin[31:12] == flin[31:12]) begin
        branch_d = mc_raw_branch_mov(ic_front_bytes[off],
            ic_front_bytes[off+5'd1], ic_front_bytes[off+5'd2]);
        if (branch_d.len != 0 &&
            ({1'b0,lin[4:0]} + {2'd0,branch_d.len} <= 6'd32) &&
            ({1'b0,pc} + {29'd0,branch_d.len} - 33'd1 <=
                {1'b0,seg_limit[SG_CS]}) &&
            ic_buffered(lin) && ic_buffered(lin+{28'd0,branch_d.len}-32'd1))
          d = branch_d;
      end
`endif""")
    text = text[:start] + raw + text[end:]
    anchor = '''`else
  assign mc_prime_u_branch = 1'b0;
  assign mc_prime_v_branch = 1'b0;
  assign mc_prime_branch = 1'b0;
`endif'''
    text = once(text, anchor, '''`elsif VEN_RAW_BRANCH_FALLTHROUGH_PRIME
  // Only predicted FALLTHROUGH, with the actual outcome checked at COMMIT.
  // Never let an ALU/flags result select a query address: it can consume L1
  // response data. OFFER is a resident-only lookup, not a speculative read.
  assign mc_prime_u_branch = !mc_valid_q && !pipe_mem_active_q &&
      !pipe_pair_lookahead && !u_pred_taken && pipe_u_eff.simple &&
      pipe_u_eff.is_branch && pipe_u_eff.br_cond && !pipe_u_eff.w16;
  assign mc_prime_v_branch = !mc_valid_q && !pipe_mem_active_q &&
      pipe_u_eff.simple && !pipe_u_eff.is_mem && !pipe_u_eff.is_store &&
      !pipe_u_eff.is_stack && !pipe_u_eff.is_fp && !pipe_u_eff.is_branch &&
      pipe_pair_lookahead && !v_pred_taken && pipe_v_eff.simple &&
      pipe_v_eff.is_branch && pipe_v_eff.br_cond && !pipe_v_eff.w16;
  assign mc_prime_branch = mc_prime_u_branch || mc_prime_v_branch;
''' + anchor)
    text = once(text, '''        // A cache-window warmup only, never consume/replace or a third decode.
        mc_prime_base && !pipe_pair_lookahead &&''', '''        // Cache-window warmup only; never retain/execute the hint descriptor.
        mc_prime_base &&
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
        (!pipe_pair_lookahead || mc_prime_v_branch) &&
`else
        !pipe_pair_lookahead &&
`endif''')
    text = once(text, '''            !pipe_pair_lookahead && mc_query_v.len == 0 &&
            mc_query_pc == (mc_fp_self_prime ? eip : pipe_commit_eip + {28'd0, pipe_u_eff.len}) &&
            !(mc_query_u.addr_mask & pipe_u_eff.writes))''', '''            (!pipe_pair_lookahead || mc_prime_v_branch) && mc_query_v.len == 0 &&
            mc_query_pc == (mc_fp_self_prime ? eip : pipe_commit_eip +
                {28'd0,pipe_u_eff.len} + (mc_prime_v_branch ? {28'd0,pipe_v_eff.len} : 32'd0)) &&
            !(mc_query_u.addr_mask & mc_older_writes))''')
    anchor = '''    end else if ((mc_held_read_prime || mc_fresh_read_prime) && ven_fetchdbg_en)'''
    text = once(text, anchor, '''    end else if (mc_prime_branch && ven_fetchdbg_en)
      $display("[FETCHDBG:RAWBRANCHPRIME] eip=%08x next=%08x addr=%08x v=%0d",
               eip, mc_query_pc, mc_query_phys, mc_prime_v_branch);
    else if ((mc_held_read_prime || mc_fresh_read_prime) && ven_fetchdbg_en)''')
    return text


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if source == output:
        raise ValueError('private output must differ from source')
    original = source.read_bytes()
    changed = transform(original.decode()).encode()
    leaf = (HERE/'raw-branch-mov.svh').read_bytes()
    if output.exists() or (output.parent/LEAF).exists():
        raise FileExistsError('candidate or companion leaf already exists')
    with output.open('xb') as f:
        f.write(changed)
    with (output.parent/LEAF).open('xb') as f:
        f.write(leaf)
    assert source.read_bytes() == original
    return dict(source=str(source), source_sha256=hashlib.sha256(original).hexdigest(),
        candidate=str(output), candidate_sha256=hashlib.sha256(changed).hexdigest(),
        leaf_sha256=hashlib.sha256(leaf).hexdigest(), production_changed=False,
        gameplay_ipc=None, standard_suite=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.out), indent=2))
