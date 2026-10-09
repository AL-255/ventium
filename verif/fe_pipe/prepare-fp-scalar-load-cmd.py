#!/usr/bin/env python3
"""Private final-operand handoff for scalar FIAR32 and FCOM32/64.

Only the command whitelist changes. The existing final fragment ACK, precise
FSM/debug gate, command owner, leaf ready and ordered retirement remain intact.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_FP_SCALAR_LOAD_CMD'
ANCHOR = '''       (q_fxop == FX_AR_M32) || (q_fxop == FX_AR_M64));
  assign fp_shared_cmd_mem = !fp_shared_load_cmd ? f_mem80 :'''
REPLACEMENT = '''       (q_fxop == FX_AR_M32) || (q_fxop == FX_AR_M64)
`ifdef VEN_FP_SCALAR_LOAD_CMD
       // Read-only, complete operands, no new queue class or execution unit.
       // Retain the old S_FEXEC route when exceptions are unmasked/pending.
       || ((q_fxop inside {FX_AR_I32, FX_FCOM_M32, FX_FCOM_M64}) &&
           (fctrl[5:0] == 6'h3f) && !fstat[7])
`endif
      );
  assign fp_shared_cmd_mem = !fp_shared_load_cmd ? f_mem80 :'''


def transform(text):
    if FLAG in text or text.count(ANCHOR) != 1:
        raise ValueError('already applied or ambiguous final-operand handoff')
    return text.replace(ANCHOR, REPLACEMENT)


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source/output must be disjoint')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    target = 'rtl/core/core.sv'
    changed = transform((source/target).read_text())
    shutil.copytree(source, output)
    (output/target).write_text(changed)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins)
    assert [p for p in pins if pins[p] != actual[p]] == [target]
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(parent=str(source), parent_pins=pins, candidate_pins=actual,
                added_define=FLAG, production=False, standard_suite=False, gameplay_ipc=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.out)
    with (args.out/'fp-scalar-load-cmd-inputs.json').open('x') as f:
        json.dump(result, f, indent=2)
