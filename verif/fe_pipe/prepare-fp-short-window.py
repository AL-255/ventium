#!/usr/bin/env python3
"""Private x87 byte-window capture; the ordinary slow decoder still executes it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_FP_SHORT_WINDOW'
PREDICATE = '''`ifdef VEN_FP_SHORT_WINDOW
  // An unprefixed x87 instruction is 2..7 bytes, not a 16-byte fetch demand.
  // Decode length comes from the SAME reference decoder and every byte of
  // that encoding must already have a current registered I-cache owner.
  // This only copies ibuf. S_DECODE retains all #NM/#MF, event, debug, memory,
  // environment/stack and execution decisions; it is not x87 fast dispatch.
  logic pipe_fp_short_window_ok;
  assign pipe_fp_short_window_ok = (state == S_PIPE) && cycle_mode && !def16
                       && !pipe_fetch_checked_handoff
                       && !d_unknown && d_is_x87 &&
                          (refdecode_ibuf[0] inside {[8'hd8:8'hdf]})
                       && (d_len >= 4'd2) && (d_len <= 4'd7)
                       && exec_issue_ok && !icsnp_v1 && !icsnp_v2
`ifdef VEN_L1_AXI
                       && !ic_snoop_valid
`endif
                       && ({1'b0,flin[11:0]} + {9'd0,d_len} <= 13'd4096)
                       && (!sys_mode || (!real_mode && !v86 &&
                           ({1'b0,eip} + {29'd0,d_len} - 33'd1 <=
                            {1'b0,seg_limit[SG_CS]})))
                       && ic_buffered(flin)
                       && ic_buffered(flin + {28'd0,d_len} - 32'd1);
`endif
'''


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous FP byte-window anchor: ' + old)
    return text.replace(old, new)


def transform(text):
    if FLAG in text:
        raise ValueError('FP short-window feature already present')
    text = once(text, '''`ifdef VEN_PIPE_SDECODE
  task automatic pipe_capture_slow_window;''', '''`ifdef VEN_FP_SHORT_WINDOW
`ifndef VEN_PIPE_SDISPATCH_SHORT
  initial $fatal(1, "FP short window requires exact-length integer capture infrastructure");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "FP short window requires registered I-cache ownership");
`endif
`endif
''' + PREDICATE + '''`ifdef VEN_PIPE_SDECODE
  task automatic pipe_capture_slow_window;''')
    text = once(text, '''        || pipe_sdispatch_short_window_ok
`endif
       ) begin''', '''        || pipe_sdispatch_short_window_ok
`ifdef VEN_FP_SHORT_WINDOW
        || pipe_fp_short_window_ok
`endif
`endif
       ) begin''')
    text = once(text, '''      state <= S_DECODE;
`ifdef VEN_PIPE_SDISPATCH
      if (pipe_sdispatch_shape_ok) begin''', '''      state <= S_DECODE;
`ifndef SYNTHESIS
`ifdef VEN_FP_SHORT_WINDOW
      if (ven_fetchdbg_en && pipe_fp_short_window_ok && !pipe_sdecode_window_ok)
        $display("[FETCHDBG:FP-SHORT] eip=%08x flin=%08x len=%0d", eip, flin, d_len);
`endif
`endif
`ifdef VEN_PIPE_SDISPATCH
      if (pipe_sdispatch_shape_ok) begin''')
    return text


def pins(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output cannot be inside source')
    before = pins(source)
    leaf = 'rtl/core/core.sv'
    changed = transform((source / leaf).read_text())
    shutil.copytree(source, output)
    (output / leaf).write_text(changed)
    after = pins(output)
    assert before.keys() == after.keys()
    assert [p for p in before if before[p] != after[p]] == [leaf]
    assert pins(source) == before
    record = dict(parent=str(source), parent_pins=before, candidate_pins=after,
                  gameplay_ipc=None, standard_suite=False, production_selected=False)
    (output / 'fp-short-window-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
