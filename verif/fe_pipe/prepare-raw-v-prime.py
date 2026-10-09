#!/usr/bin/env python3
"""Private prototype: prime a resident V read without reserving its next U/V pair.

The normal decoder/permission path still admits the load. This only uses the
existing read lookahead port to warm its registered cache window. No new decoder,
backing request, speculative write, third instruction, or architectural owner.
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


def prepare(source, output):
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output must not be nested in source')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    shutil.copytree(source, output)
    path = output/'rtl/core/core_mem_chain.svh'
    text = path.read_text()
    text = once(text, '`ifndef VEN_UOPCACHE\n  initial $fatal',
        '`ifndef VEN_UOPCACHE\n`ifndef VEN_RAW_V_READ_PRIME\n  initial $fatal')
    text = once(text, 'requires VEN_UOPCACHE");\n`endif',
        'requires VEN_UOPCACHE");\n`endif\n`endif')
    text = once(text, '  // Read the *existing returned* uop windows,', '''`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_UOPCACHE
  initial $fatal(1, "raw V read prime must use the ordinary raw decoders");
`endif
`ifndef VEN_PIPE_REG_LOAD_PRIME
  initial $fatal(1, "raw V read prime requires the resident prime port");
`endif
`ifdef VEN_PIPE_BRANCH_LOAD_PRIME
  initial $fatal(1, "raw V read prime does not decode branch successors");
`endif
  function automatic fpd_t mc_descriptor(input logic [31:0] pc);
    logic [31:0] lin;
    fpd_t d;
    begin
      lin = seg_base[SG_CS] + pc;
      d = '0;
      // Never retain a raw descriptor through an active memory owner. Only
      // the currently checked V bytes may lend their already decoded packet.
      if (!pipe_mem_active_q && !mc_valid_q && !pipe_pair_lookahead &&
          v_bytes_ok && pc == eip + {28'd0, u_d.len} &&
          lin[31:12] == flin[31:12] && v_d.len != 0 &&
          ({1'b0, lin[4:0]} + {2'd0, v_d.len} <= 6'd32) &&
          ({1'b0, pc} + {29'd0, v_d.len} - 33'd1 <=
              {1'b0, seg_limit[SG_CS]})) d = v_d;
      return d;
    end
  endfunction
`else
  // Read the *existing returned* uop windows,''')
    text = once(text, '  // While a candidate is waiting, prepare its successor',
        '`endif\n\n  // While a candidate is waiting, prepare its successor')
    text = once(text, '    mc_prepare_ok = mc_boundary_ok &&', '''    mc_prepare_ok = mc_boundary_ok &&
`ifdef VEN_RAW_V_READ_PRIME
        // A cache-window warmup only, never consume/replace or a third decode.
        mc_prime_base && !pipe_pair_lookahead &&
`endif''')
    text = once(text, '`ifndef SYNTHESIS\n  always_ff', '''`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
  always_ff @(posedge clk) if (rst_n && mc_prime_accept) begin
    assert (!mc_valid_q && !mc_chain_accept && !pipe_mem_active_q &&
            !pipe_pair_lookahead && mc_query_v.len == 0 &&
            mc_query_pc == eip + {28'd0, u_d.len} &&
            !(mc_query_u.addr_mask & pipe_u_eff.writes))
      else $fatal(1, "raw V read prime descriptor/address ownership");
    if (ven_fetchdbg_en)
      $display("[FETCHDBG:RAWPRIME] eip=%08x next=%08x addr=%08x",
               eip, mc_query_pc, mc_query_phys);
  end
`endif
  always_ff''')
    path.write_text(text)
    path = output/'rtl/core/core.sv'
    text = once(path.read_text(), '      end else if (mc_prime_accept) begin',
        '''`ifndef VEN_RAW_V_READ_PRIME
      // Raw V priming only warms the L1 window: ordinary admission on the
      // next cycle must retain the opportunity to pair this load with V.
      end else if (mc_prime_accept) begin''')
    text = once(text, '      end else if (!pipe_mem_active_q && pipe_new_mem_req',
        '`endif\n      end else if (!pipe_mem_active_q && pipe_new_mem_req')
    # The permission-carrying FE child must only consume its ordinary parent's
    # metadata. Cache-only priming does not own an instruction and need not seed
    # that child. Keep the existing fatal for actual consume/replace chains.
    text = once(text,
        '  initial $fatal(1, "VEN_FE_DTLB_PERM memory-chain permission capture is not qualified");',
        '`ifndef VEN_RAW_V_READ_PRIME\n'
        '  initial $fatal(1, "VEN_FE_DTLB_PERM memory-chain permission capture is not qualified");\n'
        '`endif')
    for signal in ('mc_accept', 'mc_prime_accept'):
        old = f'if ({signal} && paging_on) begin'
        assert text.count(old) == 2  # multi-page child and legacy one-page cut
        text = text.replace(old, f'''if ({signal} && paging_on
`ifdef VEN_RAW_V_READ_PRIME
        && 1'b0 // only warms L1; ordinary admission owns FE capture/permissions
`endif
        ) begin''')
    path.write_text(text)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins)
    assert sorted(p for p in pins if pins[p] != actual[p]) == [
        'rtl/core/core.sv', 'rtl/core/core_mem_chain.svh']
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h
               for p, h in pins.items())
    return dict(source=str(source), parent_pins=pins, candidate_pins=actual,
                gameplay_ipc=None, standard_suite=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.out)
    (args.out/'raw-v-prime-inputs.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
