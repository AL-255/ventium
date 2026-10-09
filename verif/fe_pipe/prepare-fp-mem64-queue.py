#!/usr/bin/env python3
"""Private extension of the one ordered FP slot to fully acquired m64 sources."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

FLAG = 'VEN_FP_MEM_QUEUE64'
CORE = 'rtl/core/core_fp_async.svh'
QUEUE = 'fp_shared/ven_fp_fxch_queue.sv'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous source anchor: '+old)
    return text.replace(old, new)


def core(text):
    if FLAG in text:
        raise ValueError('wide queue already present')
    old = '''      q_f_mem_read && !q_f_mem_write && (q_f_mbytes == 4'd4) && !q_f_pop &&
      ((q_fxop == FX_FLD_M32) || (q_fxop == FX_FILD_M32) ||
       ((q_fxop == FX_AR_M32) &&
        ((q_f_aluop == 3'd0) || (q_f_aluop == 3'd1) || (q_f_aluop >= 3'd4)))) &&'''
    new = '''      q_f_mem_read && !q_f_mem_write && !q_f_pop && (
      ((q_f_mbytes == 4'd4) &&
       ((q_fxop == FX_FLD_M32) || (q_fxop == FX_FILD_M32) ||
        ((q_fxop == FX_AR_M32) &&
         ((q_f_aluop == 3'd0) || (q_f_aluop == 3'd1) || (q_f_aluop >= 3'd4)))))
`ifdef VEN_FP_MEM_QUEUE64
      || ((q_f_mbytes == 4'd8) &&
          ((q_fxop == FX_FLD_M64) || (q_fxop == FX_FILD_M64) ||
           ((q_fxop == FX_AR_M64) &&
            ((q_f_aluop == 3'd0) || (q_f_aluop == 3'd1) || (q_f_aluop >= 3'd4)))))
`endif
      ) &&'''
    text = once(text, old, new)
    # The second occurrence is the final-old-response/immediate-load boundary
    # assertion, not merely diagnostic text. Keep both ownership lists aligned.
    old = '(fp_async_cmd_op == FX_FILD_M32)))'
    if text.count(old) != 2:
        raise ValueError('deferred/immediate load-owner anchors drifted')
    return text.replace(old, '''(fp_async_cmd_op == FX_FILD_M32)
`ifdef VEN_FP_MEM_QUEUE64
       || (fp_async_cmd_op == FX_FLD_M64) || (fp_async_cmd_op == FX_FILD_M64)
`endif
       ))''')


def queue(text):
    if FLAG in text:
        raise ValueError('wide queue already present')
    text = once(text, '  logic queued, leaf_valid, leaf_ready, leaf_accept_retire, leaf_busy;', '''`ifdef VEN_FP_MEM_QUEUE64
`ifndef VEN_FP_MEM_QUEUE
  initial $fatal(1, "VEN_FP_MEM_QUEUE64 requires the existing ordered memory queue");
`endif
`endif
  logic queued, leaf_valid, leaf_ready, leaf_accept_retire, leaf_busy;''')
    text = once(text, '  logic [31:0] saved_mem;', '''`ifdef VEN_FP_MEM_QUEUE64
  // One shared slot, 32 extra payload bits and one width bit. ST0/TOP/tags
  // are still resolved by the original leaf in order, never snapshotted here.
  logic [63:0] saved_mem;
  logic saved_mem_wide;
`else
  logic [31:0] saved_mem;
`endif''')
    text = once(text, '''  assign mem_queue_shape = (cmd_mem_bytes == 4'd4) && !cmd_pop &&
      ((cmd_op == FX_FLD_M32) || (cmd_op == FX_FILD_M32) ||
       ((cmd_op == FX_AR_M32) &&
        ((cmd_aluop == 3'd0) || (cmd_aluop == 3'd1) ||
         (cmd_aluop >= 3'd4))));''', '''  assign mem_queue_shape = !cmd_pop && (
      ((cmd_mem_bytes == 4'd4) &&
       ((cmd_op == FX_FLD_M32) || (cmd_op == FX_FILD_M32) ||
        ((cmd_op == FX_AR_M32) &&
         ((cmd_aluop == 3'd0) || (cmd_aluop == 3'd1) || (cmd_aluop >= 3'd4)))))
`ifdef VEN_FP_MEM_QUEUE64
      || ((cmd_mem_bytes == 4'd8) &&
          ((cmd_op == FX_FLD_M64) || (cmd_op == FX_FILD_M64) ||
           ((cmd_op == FX_AR_M64) &&
            ((cmd_aluop == 3'd0) || (cmd_aluop == 3'd1) || (cmd_aluop >= 3'd4)))))
`endif
      );''')
    text = once(text, '      saved_fdiv_bug <= 0;', '''      saved_fdiv_bug <= 0;
`ifdef VEN_FP_MEM_QUEUE64
      saved_mem_wide <= 0;
`endif''')
    text = once(text, '      saved_mem <= cmd_mem[31:0]; saved_fdiv_bug <= cmd_fdiv_bug;', '''`ifdef VEN_FP_MEM_QUEUE64
      saved_mem <= cmd_mem[63:0];
      saved_mem_wide <= (cmd_mem_bytes == 4'd8);
`else
      saved_mem <= cmd_mem[31:0];
`endif
      saved_fdiv_bug <= cmd_fdiv_bug;''')
    text = once(text, '''    .cmd_mem(queued ? {48'd0, saved_mem} : cmd_mem),
    .cmd_mem_bytes(queued ? 4'd4 : cmd_mem_bytes),''', '''`ifdef VEN_FP_MEM_QUEUE64
    .cmd_mem(queued ? {16'd0, saved_mem} : cmd_mem),
    .cmd_mem_bytes(queued ? (saved_mem_wide ? 4'd8 : 4'd4) : cmd_mem_bytes),
`else
    .cmd_mem(queued ? {48'd0, saved_mem} : cmd_mem),
    .cmd_mem_bytes(queued ? 4'd4 : cmd_mem_bytes),
`endif''')
    return text


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source/output must be disjoint')
    pins = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.rglob('*') if p.is_file()}
    changed = {CORE: core((source/CORE).read_text()), QUEUE: queue((source/QUEUE).read_text())}
    shutil.copytree(source, output)
    for name, content in changed.items():
        (output/name).write_text(content)
    after = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in output.rglob('*') if p.is_file()}
    assert set(after) == set(pins)
    assert {p for p in pins if pins[p] != after[p]} == {CORE, QUEUE}
    assert all(hashlib.sha256((source/p).read_bytes()).hexdigest() == h for p,h in pins.items())
    return dict(parent=str(source),parent_pins=pins,candidate_pins=after,added_define=FLAG,
                production=False,standard_suite=False,gameplay_ipc=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source,args.out)
    with (args.out/'fp-mem64-queue-inputs.json').open('x') as f:
        json.dump(result,f,indent=2)
