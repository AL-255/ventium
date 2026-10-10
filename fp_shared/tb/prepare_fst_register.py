#!/usr/bin/env python3
"""Exact two-file FST-register repair for a private, already-pinned closure.

No pipeline scheduling, queue, floating-point arithmetic, or exception mask
changes. A register destination is not a source, and an exact register copy
clears C1. Existing final stack-fault overrides still take precedence.
"""
from pathlib import Path


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('FST repair source anchor is missing or ambiguous: '+before)
    return text.replace(before, after)


def transform_shared(text):
    text = once(text,
        "      FX_FST_STI:\n        begin issue_reads_st0 = 1'b1; issue_reads_sti = 1'b1; end",
        "      // ST(i) is a write destination, including when its tag is empty.\n"
        "      FX_FST_STI: issue_reads_st0 = 1'b1;")
    return once(text,
        "          c_write_valid = 1'b1;\n          c_pop         = cmd_pop ? 2'd1 : 2'd0;\n        end\n        FX_FFREE:",
        "          c_write_valid = 1'b1;\n          c_pop         = cmd_pop ? 2'd1 : 2'd0;\n"
        "          // No format conversion: register FST/FSTP cannot round up.\n"
        "          c_status      = 1'b1;\n          c_status_data = fstat_o & ~16'h0200;\n"
        "        end\n        FX_FFREE:")


def transform_legacy(text):
    text = once(text, "        FK_FSTP0:  begin fp_we_pop=1'b1; end",
        "        FK_FSTP0: begin\n          fp_we_pop=1'b1;\n"
        "          fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h0200;\n        end")
    text = once(text,
        "          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_st0v; fp_wsti_clr_tag=1'b1;\n          if (q_f_pop) fp_we_pop=1'b1;",
        "          fp_we_sti=1'b1; fp_wsti_idx=q_f_sti; fp_wsti_data=s_st0v; fp_wsti_clr_tag=1'b1;\n"
        "          if (q_f_pop) fp_we_pop=1'b1;\n"
        "          fp_we_fstat=1'b1; fp_fstat_wval=fstat & ~16'h0200;")
    text = once(text,
        "    //                 FST ST(i), and FLD ST(i) (whose SOURCE is ST(i); its destination\n"
        "    //                 is covered by the push/overflow term above).",
        "    //                 and FLD ST(i) (whose SOURCE is ST(i); its destination\n"
        "    //                 is covered by the push/overflow term above). FST ST(i)\n"
        "    //                 only reads ST0: an empty ST(i) destination is legal.")
    return once(text,
        "                || (q_fxop==FX_FST_STI)    || (q_fxop==FX_FLD_STI)",
        "                || (q_fxop==FX_FLD_STI)")


TRANSFORMS = {'fp_shared/ven_fp_top.sv': transform_shared,
              'rtl/core/fpu_writeback.sv': transform_legacy}


def prepare(root):
    """Validate all anchors before mechanically applying either file."""
    root = Path(root)
    outputs = {root/name: fn((root/name).read_text()) for name,fn in TRANSFORMS.items()}
    for path,text in outputs.items():
        path.write_text(text)
