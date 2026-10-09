#!/usr/bin/env python3
"""Private experiment: prepare a resident x87 operand window on admission.

Requires the raw-V cache-only parent, not a memory-owner replacement chain.
S_FLOAD still owns every request, translation/fault and architectural result.
No backing request, extra port, early FPU command or instruction retirement.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'expected one source anchor: {old!r}')
    return text.replace(old, new)


def restrict_arith32(text):
    return once(text, '''  assign mc_fp_self_prime = pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM &&
                           !mc_valid_q && !pipe_mem_active_q;''', '''  // Only one-beat arithmetic can consume the shortened admission without
  // replacing its saved load clock with another execution/stack wait. Do not
  // perturb FLD/FILD scheduling or spend the hint on two-beat operands.
  assign mc_fp_self_prime = pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM &&
                           pipe_u_eff.fp_role == 3'd0 && !pipe_u_eff.fp_sti[0] &&
                           !pipe_u_eff.fp_aluop[1] &&
                           !mc_valid_q && !pipe_mem_active_q;''')


def prepare(source, output, *, arith32=False):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output may not be nested inside source')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    if arith32 and 'VEN_FP_ARITH_MEM_FWD' not in (source/'fp_shared/ven_fp_top.sv').read_text():
        raise ValueError('arith32 priming requires the memory-forwarding source')
    shutil.copytree(source, output)
    path = output/'rtl/core/core_mem_chain.svh'
    text = path.read_text()
    text = once(text, '  // While a candidate is waiting, prepare its successor', '''  logic mc_fp_self_prime;
`ifdef VEN_FP_RESIDENT_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "FP resident prime requires cache-only raw priming");
`endif
`ifndef VEN_FP_MEM_ADMIT
  initial $fatal(1, "FP resident prime requires checked FP memory admission");
`endif
  // Select a cache-only query without consuming ACK-dependent admission.
  // The actual checked admission gates COMMIT, never the lookup address.
  // No integer memory owner or third decoded instruction is involved.
  assign mc_fp_self_prime = pipe_u_eff.is_fp && pipe_u_eff.fp_kind == FK_MEM &&
                           !mc_valid_q && !pipe_mem_active_q;
`else
  assign mc_fp_self_prime = 1'b0;
`endif

  // While a candidate is waiting, prepare its successor''')
    text = once(text, "      d = '0;\n      // Never retain", """      d = '0;
      // The admitted current x87 descriptor already owns complete checked
      // frontend bytes. Only a full-in-line form can prime this cache window.
      if (mc_fp_self_prime && pc == eip &&
          ({1'b0, lin[4:0]} + {2'd0, pipe_u_eff.len} <= 6'd32) &&
          ({1'b0, pc} + {29'd0, pipe_u_eff.len} - 33'd1 <=
              {1'b0, seg_limit[SG_CS]})) d = pipe_u_eff;
      // Never retain""")
    text = once(text, '      if (!pipe_mem_active_q && !mc_valid_q && !pipe_pair_lookahead &&',
        '      if (!mc_fp_self_prime && !pipe_mem_active_q && !mc_valid_q && !pipe_pair_lookahead &&')
    text = once(text, '  assign mc_query_pc = mc_valid_q',
        '  assign mc_query_pc = mc_fp_self_prime ? eip : mc_valid_q')
    text = once(text, '  assign mc_query_v = mc_descriptor(mc_query_vpc);',
        "  assign mc_query_v = mc_fp_self_prime ? '0 : mc_descriptor(mc_query_vpc);")
    text = once(text, '  assign mc_prime_base = !mc_valid_q && !pipe_mem_active_q &&',
        '  assign mc_prime_base = mc_fp_self_prime || (!mc_valid_q && !pipe_mem_active_q &&')
    text = once(text, '(pipe_v_eff.is_branch && !mc_prime_v_branch)));',
        '(pipe_v_eff.is_branch && !mc_prime_v_branch))));')
    text = once(text, '''        mc_query_u.simple && mc_query_u.is_mem && !mc_query_u.is_store &&
        !mc_query_u.is_stack && !mc_query_u.is_fp && !mc_query_u.is_branch &&''', '''        ((mc_fp_self_prime && mc_query_u.is_fp && mc_query_u.fp_kind == FK_MEM) ||
         (mc_query_u.simple && mc_query_u.is_mem && !mc_query_u.is_fp)) &&
        !mc_query_u.is_store && !mc_query_u.is_stack && !mc_query_u.is_branch &&''')
    text = once(text, "({1'b0, mc_query_ea} + (mc_query_u.w8 ? 33'd0 : 33'd3)",
        "({1'b0, mc_query_ea} + ((mc_fp_self_prime && mc_query_u.fp_sti[0]) ?\n"
        "            33'd7 : (mc_query_u.w8 ? 33'd0 : 33'd3))")
    text = once(text, "(mc_query_u.w8 || (mc_query_lin[4:0] <= 5'd28)) &&",
        "(mc_query_u.w8 || (mc_query_lin[4:0] <=\n"
        "            ((mc_fp_self_prime && mc_query_u.fp_sti[0]) ? 5'd24 : 5'd28))) &&")
    text = once(text, '      pipe_int_commit;',
        '      (pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit));')
    text = once(text, '    assert (pipe_int_commit && !pipe_mem_active_q && !pipe_new_mem_req &&',
        '    assert ((pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)) &&\n'
        '            !pipe_mem_active_q && !pipe_new_mem_req &&')
    text = once(text, '    assert (mc_prime_branch ||\n            mc_query_pc == pipe_commit_eip',
        '    assert ((mc_fp_self_prime && mc_query_pc == eip) || mc_prime_branch ||\n            mc_query_pc == pipe_commit_eip')
    # The raw-V assertion still requires zero third-descriptor/owner state;
    # distinguish the new current-FP admission from the old following-V hint.
    text = once(text, "            mc_query_pc == eip + {28'd0, u_d.len} &&",
        "            mc_query_pc == (mc_fp_self_prime ? eip : eip + {28'd0, u_d.len}) &&")
    text = once(text, '    if (ven_fetchdbg_en)\n      $display("[FETCHDBG:RAWPRIME]',
        '''    if (mc_fp_self_prime) begin
      assert (fp_shared_mem_admit && mc_query_u.is_fp && mc_query_u.fp_kind == FK_MEM &&
              !pipe_int_commit && !pipe_new_mem_req && !mc_query_u.is_mem)
        else $fatal(1, "FP resident prime is not cache-only admission");
      if (ven_fetchdbg_en)
        $display("[FETCHDBG:FPPRIME] eip=%08x addr=%08x wide=%0d",
                 eip, mc_query_phys, mc_query_u.fp_sti[0]);
    end else if (ven_fetchdbg_en)
      $display("[FETCHDBG:RAWPRIME]''')
    if arith32:
        text = restrict_arith32(text)
    path.write_text(text)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins)
    assert [p for p in pins if pins[p] != actual[p]] == ['rtl/core/core_mem_chain.svh']
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(source=str(source),parent_pins=pins,candidate_pins=actual,
                gameplay_ipc=None,standard_suite=False,arith32_only=arith32)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--arith32',action='store_true')
    args = parser.parse_args()
    result = prepare(args.source,args.out,arith32=args.arith32)
    (args.out/'fp-resident-prime-inputs.json').write_text(json.dumps(result,indent=2)+'\n')
