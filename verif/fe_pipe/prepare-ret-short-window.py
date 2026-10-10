#!/usr/bin/env python3
"""Private near-RET byte capture proposal; retain ordinary S_DECODE/execution."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG = 'VEN_RET_SHORT_WINDOW'
PREDICATE = '''`ifdef VEN_RET_SHORT_WINDOW
`ifndef VEN_PIPE_SDISPATCH_SHORT
  initial $fatal(1, "RET short window requires exact-length capture infrastructure");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "RET short window requires registered I-cache ownership");
`endif
  // Unprefixed near RET needs one or three code bytes, not an unconditional
  // 16-byte window. Only capture those already owned instruction bytes here.
  // S_DECODE/S_LOAD/S_EXEC still own stack width, SS/page/code-target checks,
  // debug/events, architectural ESP/EIP updates and execution occupancy.
  logic pipe_ret_short_window_ok;
  assign pipe_ret_short_window_ok = (state == S_PIPE) && cycle_mode && !def16
                       && !pipe_fetch_checked_handoff && !d_unknown
                       && (d_kind == K_CTRL)
                       && (((refdecode_ibuf[0] == 8'hc3) &&
                            (d_ct == CT_RETN) && (d_len == 4'd1)) ||
                           ((refdecode_ibuf[0] == 8'hc2) &&
                            (d_ct == CT_RETN_IMM) && (d_len == 4'd3)))
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
        raise ValueError('missing/ambiguous near-RET capture anchor: ' + old)
    return text.replace(old, new)


def transform(text):
    if FLAG in text:
        raise ValueError('RET short window already present')
    # The existing suffix blanking is mandatory; this must never authorize a
    # short capture while copying unowned trailing bytes into the slow decoder.
    suffix = "        if (!pipe_sdecode_window_ok && (i >= int'(d_len)))\n          ibuf[i] <= 8'd0;"
    if text.count(suffix) != 1:
        raise ValueError('missing/ambiguous exact-length suffix blanking')
    anchor = '`ifdef VEN_PIPE_SDECODE\n  task automatic pipe_capture_slow_window;'
    text = once(text, anchor, PREDICATE + anchor)
    anchor = '        || pipe_sdispatch_short_window_ok\n'
    text = once(text, anchor, anchor + '''`ifdef VEN_RET_SHORT_WINDOW
        || pipe_ret_short_window_ok
`endif
''')
    anchor = '      state <= S_DECODE;\n'
    # Limit the insertion to this task: other decoder paths have the same state.
    start = text.index('  task automatic pipe_capture_slow_window;')
    end = text.index('  endtask', start)
    task = text[start:end]
    task = once(task, anchor, anchor + '''`ifdef VEN_RET_SHORT_WINDOW
`ifndef SYNTHESIS
      if (ven_fetchdbg_en && pipe_ret_short_window_ok && !pipe_sdecode_window_ok)
        $display("[FETCHDBG:RET-SHORT] eip=%08x flin=%08x len=%0d", eip, flin, d_len);
`endif
`endif
''')
    return text[:start] + task + text[end:]


def prepare(source, output):
    source = source.resolve(strict=True)
    output = output.resolve()
    if source == output:
        raise ValueError('private output must differ from source')
    before = source.read_bytes()
    candidate = transform(before.decode()).encode()
    with output.open('xb') as stream:
        stream.write(candidate)
    assert source.read_bytes() == before
    return dict(source=str(source), source_sha256=hashlib.sha256(before).hexdigest(),
                candidate=str(output), candidate_sha256=hashlib.sha256(candidate).hexdigest(),
                production_changed=False, gameplay_ipc=None, standard_suite=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.out), indent=2))
