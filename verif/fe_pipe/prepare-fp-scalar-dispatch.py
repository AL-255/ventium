#!/usr/bin/env python3
"""Private, default-off scalar x87 reference-packet dispatch experiment."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
FLAG = 'VEN_FP_SCALAR_DISPATCH'
ANCHOR = '`ifdef VEN_PIPE_SDECODE\n  task automatic pipe_capture_slow_window;'
TAIL = '''        state <= d_mem_read ? S_LOAD : S_EXEC;
      end
`endif
    end
  endtask'''
DISPATCH = '''        state <= d_mem_read ? S_LOAD : S_EXEC;
      end
`endif
`ifdef VEN_FP_SCALAR_DISPATCH
      if (pipe_fp_scalar_dispatch_ok) begin
        // The same reference packet and issue-time flags as S_DECODE. No
        // operand read, FPU command, stack update or retirement on this edge.
        capture_reference_decode(eip);
        if (sys_mode && !dbg_block_issue) begin
          tf_at_issue <= eflags[8];
          rf_at_issue <= eflags[16];
        end
        state <= S_FLOAD;
`ifndef SYNTHESIS
        if (ven_fetchdbg_en)
          $display("[FETCHDBG:FP-SDISPATCH] eip=%08x fxop=%0d bytes=%0d write=%0b",
                   eip, d_fxop, d_f_mbytes, d_f_mem_write);
`endif
      end
`endif
    end
  endtask'''


def transform(text):
    if FLAG in text or 'core_fp_scalar_dispatch.svh' in text:
        raise ValueError('scalar FP dispatch already present')
    for anchor in (ANCHOR, TAIL):
        if text.count(anchor) != 1:
            raise ValueError('missing/ambiguous source anchor: ' + anchor)
    return text.replace(ANCHOR, '`include "core_fp_scalar_dispatch.svh"\n' + ANCHOR).replace(TAIL, DISPATCH)


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source/output must be disjoint')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    target, helper = 'rtl/core/core.sv', 'rtl/core/core_fp_scalar_dispatch.svh'
    changed = transform((source/target).read_text())
    assert helper not in pins
    shutil.copytree(source, output)
    (output/target).write_text(changed)
    shutil.copyfile(HERE/'core_fp_scalar_dispatch.svh', output/helper)
    actual = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins) | {helper}
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
    with (args.out/'fp-scalar-dispatch-inputs.json').open('x') as f:
        json.dump(result, f, indent=2)
