#!/usr/bin/env python3
"""Private default-off registered-read successor priming; no owner replacement."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'expected one source anchor: {old!r}')
    return text.replace(old, new)


def transform(text):
    if 'core_raw_held_prime.svh' in text:
        raise ValueError('held-read prime already installed')
    text = once(text, '`ifdef VEN_RAW_V_READ_PRIME\n`ifdef VEN_UOPCACHE',
                '`include "core_raw_held_prime.svh"\n\n`ifdef VEN_RAW_V_READ_PRIME\n`ifdef VEN_UOPCACHE')
    text = once(text, '      return d;\n    end\n  endfunction\n`else', '''      // A held U lends only its originally checked unpaired V descriptor.
      // The ordinary next-U path still performs translation and execution.
      if (mc_held_read_prime && pc == pipe_mem_eip_q + {28'd0, pipe_mem_u_q.len})
        d = pipe_mem_v_q;
      return d;
    end
  endfunction
`else''')
    text = once(text, 'assign mc_prime_base = mc_fp_self_prime || (',
                'assign mc_prime_base = mc_fp_self_prime || mc_held_read_prime || mc_fresh_read_prime || (')
    text = once(text, 'assert (!mc_valid_q && !mc_chain_accept && !pipe_mem_active_q &&',
                'assert (!mc_valid_q && !mc_chain_accept && (!pipe_mem_active_q || mc_held_read_prime) &&')
    text = once(text, 'mc_query_pc == (mc_fp_self_prime ? eip : eip + {28\'d0, u_d.len})',
                'mc_query_pc == (mc_fp_self_prime ? eip : pipe_commit_eip + {28\'d0, pipe_u_eff.len})')
    text = once(text, '    end else if (ven_fetchdbg_en)\n      $display("[FETCHDBG:RAWPRIME]',
                '''    end else if ((mc_held_read_prime || mc_fresh_read_prime) && ven_fetchdbg_en)
      $display("[FETCHDBG:HELDPRIME] eip=%08x next=%08x addr=%08x",
               pipe_commit_eip, mc_query_pc, mc_query_phys);
    else if (ven_fetchdbg_en)
      $display("[FETCHDBG:RAWPRIME]''')
    text = once(text, '            !pipe_mem_active_q && !pipe_new_mem_req &&',
                '            (mc_held_read_prime || mc_fresh_read_prime || (!pipe_mem_active_q && !pipe_new_mem_req)) &&')
    text += '''
`ifdef VEN_RAW_HELD_READ_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "held read prime requires raw V read prime");
`endif
`ifndef VEN_PIPE_MEM_CHAIN
  initial $fatal(1, "held read prime requires the registered next-read port");
`endif
`endif
'''
    return text


def prepare(source, output):
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output must not be nested in source')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    target = 'rtl/core/core_mem_chain.svh'
    changed = transform((source / target).read_text())
    helper = 'rtl/core/core_raw_held_prime.svh'
    assert helper not in pins
    shutil.copytree(source, output)
    (output / target).write_text(changed)
    shutil.copyfile(HERE / 'core_raw_held_prime.svh', output / helper)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins) | {helper}
    assert [p for p in pins if pins[p] != actual[p]] == [target]
    assert all(hashlib.sha256((source / p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(parent=str(source), parent_pins=pins, candidate_pins=actual,
                added_define='VEN_RAW_HELD_READ_PRIME', gameplay_ipc=None,
                standard_suite=False, production=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.out)
    with (args.out / 'held-read-prime-inputs.json').open('x') as stream:
        json.dump(result, stream, indent=2)


if __name__ == '__main__':
    main()
