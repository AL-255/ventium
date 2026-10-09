#!/usr/bin/env python3
"""Private, default-off extension of the registered x87 result bypass.

Memory arithmetic already selects arith_operand_st0. Permit its existing
stage-2 result source under the same stack/exception/earlier-owner guards.
No extra arithmetic, early memory command, or architectural commit path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def transform(text):
    def once(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError(f'expected exactly one anchor: {old!r}')
        text = text.replace(old, new)
    if 'VEN_FP_ARITH_MEM_FWD' in text:
        raise ValueError('memory forwarding already present')
    once('  wire logic accept = cmd_valid & cmd_ready;', '''`ifdef VEN_FP_ARITH_MEM_FWD
`ifndef VEN_FP_ARITH_FWD
  initial $fatal(1, "VEN_FP_ARITH_MEM_FWD requires registered arithmetic forwarding");
`endif
`endif
  wire logic accept = cmd_valid & cmd_ready;''')
    once('''      arith_owner_valid[2] && !arith_owner_pop[2] && arith_stream_eligible &&
      ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0));''', '''      arith_owner_valid[2] && !arith_owner_pop[2] && arith_stream_eligible &&
      ((cmd_op == FX_AR_ST0_STI) || (cmd_op == FX_AR_STI_ST0)
`ifdef VEN_FP_ARITH_MEM_FWD
       // The memory operand is already command-owned. Forward only ST0;
       // alu_b remains the existing format-converted memory value. These
       // forms neither read STi nor change the logical stack mapping.
       || (cmd_op == FX_AR_M32) || (cmd_op == FX_AR_M64)
       || (cmd_op == FX_AR_I16) || (cmd_op == FX_AR_I32)
`endif
      );''')
    once("        if ((arith_owner_dst[2] == cmd_sti) &&",
         "        if (issue_reads_sti && (arith_owner_dst[2] == cmd_sti) &&")
    return text


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output may not be nested in source')
    def pins(root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file()}
    before = pins(source)
    payload = transform((source/'fp_shared/ven_fp_top.sv').read_text())
    shutil.copytree(source, output)
    (output/'fp_shared/ven_fp_top.sv').write_text(payload)
    after = pins(output)
    assert set(before) == set(after)
    assert [p for p in before if before[p] != after[p]] == ['fp_shared/ven_fp_top.sv']
    assert pins(source) == before
    result = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False)
    (output/'fp-memory-forward-inputs.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
