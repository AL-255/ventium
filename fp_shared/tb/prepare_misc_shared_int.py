"""Private area experiment: one integer converter for the serialized misc unit.

FIST, FRNDINT and FSCALE cannot execute together. Select their operand and RC
on the existing command-capture edge, then use one fx_to_int_ex call. No new
state, stage, register or latency. This is an equivalence proposal, not a fix
for the pre-existing arithmetic/exception semantics of these instructions.
"""


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('missing/ambiguous converter-sharing anchor: ' + before)
    return text.replace(before, after)


def transform(text):
    if text.count('fx_to_int_ex(') != 3:
        raise ValueError('expected exactly three original converter calls')
    text = once(text, '  logic [79:0] a_q, b_q;',
                '  logic [79:0] a_q, int_operand_q;')
    text = once(text, "      b_q         <= 80'd0;", "      int_operand_q <= 80'd0;")
    text = once(text, '          b_q        <= operand_b;',
                '          // Select before the existing capture register, not after conversion.\n'
                '          int_operand_q <= (op == FX_FSCALE) ? operand_b : operand_a;')
    text = once(text, '          rc_q       <= rc;',
                "          rc_q       <= (op == FX_FSCALE) ? 2'd3 : rc;")
    text = once(text, "          ri  = 66'd0;\n          width = 64;",
                '          width = (op_q == FX_FIST_M16) ? 16 :\n'
                '                  (op_q == FX_FIST_M32) ? 32 : 64;\n'
                '          // One shared converter; only the admitted opcode consumes it.\n'
                '          ri = fx_to_int_ex(int_operand_q, width, rc_q);')
    text = once(text,
                '              width = (op_q == FX_FIST_M16) ? 16 :\n'
                '                      (op_q == FX_FIST_M32) ? 32 : 64;\n', '')
    text = once(text, '              else\n                ri = fx_to_int_ex(a_q, width, rc_q);\n', '')
    text = once(text, '                ri = fx_to_int_ex(a_q, 64, rc_q);\n', '')
    text = once(text, "                ri      = fx_to_int_ex(b_q, 64, 2'd3);\n", '')
    if text.count('fx_to_int_ex(') != 1 or 'b_q' in text:
        raise ValueError('unexpected converter or old operand remains')
    return text
