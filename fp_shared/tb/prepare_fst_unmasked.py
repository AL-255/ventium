"""Compact finite memory-FST range-exception repair on a C1-repaired tree.

Use the already computed conversion exponent to register after-round tininess.
No new converter, SRAM port, execution state or globally serialized fast path.
Unmasked precision still stores/pops. Other misc operations are unchanged.
"""
from prepare_fst_memory_c1 import once


def transform_misc(text):
    text = once(text, '    output      logic        rounded_up\n',
        '    output      logic        rounded_up,\n'
        '    output      logic        tiny_nonzero\n')
    text = once(text, "\n      rounded_up <= 1'b0;", "\n      rounded_up <= 1'b0;\n"
        "      tiny_nonzero <= 1'b0;")
    text = once(text, "\n          rounded_up <= 1'b0;", "\n          rounded_up <= 1'b0;\n"
        "          tiny_nonzero <= 1'b0;")
    for bits, top, low in ((32, 30, 23), (64, 62, 52)):
        text = once(text, f'              value    <= {{{80-bits}\'d0, f{bits}[{bits-1}:0]}};',
            '              // Exact tiny results also fault when UM=0. Zeros do not.\n'
            f"              tiny_nonzero <= !fx_is_zero(a_q) && (f{bits}[{top}:{low}] == '0);\n"
            f'              value    <= {{{80-bits}\'d0, f{bits}[{bits-1}:0]}};')
    return text


def transform_top(text):
    text = once(text, '  logic        misc_ie, misc_oe, misc_ue, misc_pe, misc_rounded_up;',
        '  logic        misc_ie, misc_oe, misc_ue, misc_pe, misc_rounded_up;\n'
        '  logic        misc_tiny_nonzero, misc_fst_narrow, misc_fst_range_block;\n'
        '  logic        misc_commit_ue, misc_commit_pe;\n'
        '  // The pending owner and control word cannot change during TOP_MISC.\n'
        '  // P54 memory range exceptions suppress both store and pop; precision\n'
        '  // exceptions deliver the rounded value even with PM=0.\n'
        '  assign misc_fst_narrow = pending_op inside {FX_FST_M32, FX_FST_M64};\n'
        '  assign misc_commit_ue = misc_ue |\n'
        '                          (misc_fst_narrow && misc_tiny_nonzero && !fctrl_o[4]);\n'
        '  assign misc_fst_range_block = misc_fst_narrow &&\n'
        '      ((misc_oe && !fctrl_o[3]) || (misc_tiny_nonzero && !fctrl_o[4]));\n'
        '  assign misc_commit_pe = misc_pe && !misc_fst_range_block;')
    text = once(text, '      .rounded_up(misc_rounded_up)\n',
        '      .rounded_up(misc_rounded_up),\n      .tiny_nonzero(misc_tiny_nonzero)\n')
    start = text.index('    if ((top_state == TOP_MISC) && misc_done) begin')
    end = text.index('    if ((top_state == TOP_BCD_LOAD)', start)
    body = text[start:end]
    body = once(body, "        c_pop = pending_pop ? 2'd1 : 2'd0;",
        "        c_pop = (pending_pop && !misc_fst_range_block) ? 2'd1 : 2'd0;")
    body = once(body, 'misc_ie || misc_oe || misc_ue || misc_pe ||',
        'misc_ie || misc_oe || misc_commit_ue || misc_commit_pe ||')
    body = once(body, "(misc_ue ? 16'h0010 : 16'h0000)",
        "(misc_commit_ue ? 16'h0010 : 16'h0000)")
    body = once(body, "(misc_pe ? 16'h0020 : 16'h0000)",
        "(misc_commit_pe ? 16'h0020 : 16'h0000)")
    body = once(body, 'c_status_data[9] = misc_rounded_up;',
        'c_status_data[9] = misc_rounded_up && !misc_fst_range_block;')
    text = text[:start]+body+text[end:]
    start = text.index('        TOP_MISC: begin')
    end = text.index('        TOP_BCD_LOAD:', start)
    body = text[start:end]
    body = once(body, "{misc_ie, 1'b0, misc_oe, misc_ue, misc_pe,",
        "{misc_ie, 1'b0, misc_oe, misc_commit_ue, misc_commit_pe,")
    body = once(body, "              rsp_store_valid <= 1'b1;",
        '              rsp_store_valid <= !misc_fst_range_block;')
    return text[:start]+body+text[end:]


TRANSFORMS = {'fp_shared/ven_fp_misc.sv': transform_misc,
              'fp_shared/ven_fp_top.sv': transform_top}


def transform(sources):
    if set(sources) != set(TRANSFORMS):
        raise ValueError('exact FST range repair source pair required')
    return {name: fn(sources[name]) for name, fn in TRANSFORMS.items()}
