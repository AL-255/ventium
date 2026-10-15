"""Exact-parent shared-FPU FPREM underflow experiment; not a legacy repair.

The legacy caller explicitly keeps its previous masked-result service. Its
operand-abort/status integration is not qualified by the shared-FPU tests.
"""
import hashlib

PARENTS = {
    'rtl/fpu/fpu_srt_div.sv': 'e44f88ec27d86467dcd423c6ccf6cb1a902bb2def3615da39f580b9985c9d5a5',
    'fp_shared/ven_fp_top.sv': 'e30849fb658806d53bf4aa00691e96d3015b77287c1510771d7c5cb1985f2605',
    'rtl/core/core.sv': 'bcfe5263c7e7ee7357c46e444d7d73babc729d0fc0ead188a0b59fe89947427f',
}


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('FPREM underflow anchor drift: '+old[:70])
    return text.replace(old, new)


def transform(text, name):
    if hashlib.sha256(text.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FPREM underflow parent drift or repeated application: '+name)
    if name.endswith('fpu_srt_div.sv'):
        text = once(text, '    input  wire logic        prem1,      // rem: 1 = FPREM1 (round-nearest Q)\n',
            '    input  wire logic        prem1,      // rem: 1 = FPREM1 (round-nearest Q)\n'
            '    input  wire logic        rem_underflow_mask, // accepted remainder CW.UM\n')
        text = once(text, '// {oe, ue, pe, floatx80}  (div/sqrt) | {2\'b0, 1\'b0, rem} (rem)',
            "// {oe, ue, pe, floatx80}; remainder uses UE only")
        text = once(text, '  logic                rc2, rprem1;\n',
            '  logic                rc2, rprem1, rum;\n')
        text = once(text, "              rsmall_half <= 1'b0;\n",
            "              rsmall_half <= 1'b0;\n"
            "              rum <= rem_underflow_mask;\n")
        # Both bypasses have quotient zero. Reuse RNORM with raw A and the
        # subnormal exponent base; don't duplicate its 64-bit normalization.
        bypass = """if (!rem_underflow_mask && rem_input_a[78:64] == 15'd0 &&
                    !rem_input_a[63] && rem_input_a[63:0] != 64'd0) begin
                  S <= {16'd0, rem_input_a[63:0]}; reb <= 17'sd1;
                  rc2 <= 1'b0; rprem1 <= 1'b0; st <= ST_RNORM;
                end else begin
                  result_q <= {3'b000, rem_canonical(rem_input_a)}; st <= ST_SPECIAL;
                end"""
        text = once(text,
            "result_q <= {3'b000, rem_canonical(rem_input_a)}; st <= ST_SPECIAL;     // |rem_input_a|<|rem_input_b| or rem_input_a==0",
            bypass)
        text = once(text,
            "                    result_q <= {3'b000, rem_canonical(rem_input_a)}; st <= ST_SPECIAL;\n",
            '                    '+bypass.replace('\n', '\n    ')+'\n')
        text = once(text, """            if (e <= 0) begin
              logic signed [16:0] ome; logic [6:0] rsh;
""", """            if (e <= 0 && !rum) begin
              logic signed [16:0] wrapped_e;
              // Exact tiny results still raise unmasked UE. Stack results
              // are scaled by 2^24576, without rounding or newly raised PE.
              wrapped_e = e + 17'sd24576;
              result_q <= {3'b010, s_eff, wrapped_e[14:0], mant};
            end else if (e <= 0) begin
              logic signed [16:0] ome; logic [6:0] rsh;
""")
    elif name.endswith('ven_fp_top.sv'):
        text = once(text, '      .prem1(cmd_op == FX_FPREM1),\n',
            '      .prem1(cmd_op == FX_FPREM1),\n      .rem_underflow_mask(fctrl_o[4]),\n')
        text = once(text, """                        (srt_rem_denormal ? 16'h0002 : 16'h0000);
        if (srt_rem_ie)
""", """                        (srt_rem_denormal ? 16'h0002 : 16'h0000) |
                        (srt_result[81] ? 16'h0010 : 16'h0000);
        if (srt_rem_ie)
""")
        # The existing operand-abort override below discards numeric UE and
        # suppresses writeback; numeric underflow alone MUST commit its value.
        text = once(text, "                       ? {5'd0, srt_result[79:0]}\n",
            "                       ? {3'd0, (srt_result[81] && !srt_rem_abort),\n"
            "                          1'b0, srt_result[79:0]}\n")
    else:
        text = once(text, '    .prem1(eng_u_prem1), .a(eng_u_a),',
            "    // Legacy status integration is unchanged by the shared-FPU experiment.\n"
            "    .rem_underflow_mask(1'b1),\n    .prem1(eng_u_prem1), .a(eng_u_a),")
    return text
