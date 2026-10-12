"""Private exact-parent SRT remainder operand isolation; no latency change.

The remainder setup has its own exponent/denormal/special classification, but
receives the shared divide operand mux. In the shared FPU, FPREM/FPREM1 always
use ST0/STi, never a converted memory operand. A separate pair of wires removes
that irrelevant memory path from remainder setup without duplicating an engine.
The default-off flag also initializes the dead carry state in IDLE, as qacc
already does. All operation start, state transitions and output timing remain.
"""
import hashlib
import re

FLAG = 'VEN_SRT_REM_OPERAND_SPLIT'
HASHES = {
    'rtl/fpu/fpu_srt_div.sv': 'b53e94fbcb0f02cf1a90a110cca9144b2266808d9a8480c509e7364d50f69661',
    'fp_shared/ven_fp_top.sv': 'b9815e3904dcec5ad72ad3b308bb0a2f82c2674c0e9b7cce26e6a4aae1a15e56',
}


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('SRT operand-split anchor drift: '+old[:80])
    return text.replace(old, new)


def transform(sources):
    if set(sources) != set(HASHES):
        raise ValueError('need both SRT and shared top sources')
    for name, digest in HASHES.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != digest:
            raise ValueError('SRT operand-split source drift/reapplication: '+name)
    result = dict(sources)
    srt = sources['rtl/fpu/fpu_srt_div.sv']
    anchor = '    input  wire logic [1:0]  rc,         // x87 rounding control (fctrl[11:10])\n'
    srt = once(srt, anchor, '`ifdef '+FLAG+'''
    // Used only by accepted FD_REM. The caller supplies the same architectural
    // operands as a/b would contain, independently of the divide/memory mux.
    input  wire logic [79:0] rem_a,
    input  wire logic [79:0] rem_b,
`endif
'''+anchor)
    anchor = '`ifdef VEN_FPREM\n  // ---- remainder (FPREM/FPREM1) state'
    srt = once(srt, anchor, '`ifdef VEN_FPREM\n`ifdef '+FLAG+'''
  wire [79:0] rem_input_a = rem_a;
  wire [79:0] rem_input_b = rem_b;
`else
  wire [79:0] rem_input_a = a;
  wire [79:0] rem_input_b = b;
`endif
  // ---- remainder (FPREM/FPREM1) state''')
    begin = srt.index('              // ---- remainder setup')
    end = srt.index('            end else\n`endif', begin)
    block = srt[begin:end]
    # Only operand identifiers in the remainder setup, never DIV/SQRT inputs,
    # recurrence, rounding, result qualifiers, or mode/control selection.
    changed = re.sub(r'\ba\b', 'rem_input_a', block)
    changed = re.sub(r'\bb\b', 'rem_input_b', changed)
    assert changed != block
    srt = srt[:begin]+changed+srt[end:]
    anchor = "          qacc <= 128'sd0;\n"
    srt = once(srt, anchor, anchor+'`ifdef '+FLAG+'''
          // C is consumed only by iterative states. Every entry initializes
          // it to zero here; special-result operations never consume it.
          // Do not put input-dependent special classification on its CE.
          C <= 80'd0;
`endif
''')
    for line in ("                  C       <= 80'd0;\n",
                 "                C       <= 80'd0;\n",
                 "                C    <= 80'd0;\n"):
        srt = once(srt, '\n'+line, '\n`ifndef '+FLAG+'\n'+line+'`endif\n')
    result['rtl/fpu/fpu_srt_div.sv'] = srt
    top = sources['fp_shared/ven_fp_top.sv']
    anchor = '      .b(srt_b),\n'
    top = once(top, anchor, anchor+'`ifdef '+FLAG+'''
      .rem_a(st0_data),
      .rem_b(sti_data),
`endif
''')
    anchor = '  // All architectural mutation is concentrated in this commit decoder.\n'
    top = once(top, anchor, '`ifdef '+FLAG+'''
`ifndef SYNTHESIS
  // Check the actual shared-top operand/command mux, not merely the standalone
  // arithmetic engine. No new start, permission or exceptional-case bypass.
  always_ff @(posedge clk) if (rst_n && srt_start && srt_mode == 2'd2)
    assert (srt_a === st0_data && srt_b === sti_data)
      else $fatal(1, "SRT-REM-OPERAND: architectural operand owner changed");
`endif
`endif

'''+anchor)
    result['fp_shared/ven_fp_top.sv'] = top
    return result
