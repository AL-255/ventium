"""Private/default-off removal of admission from shared-SRT operand selection.

Start keeps its complete original predicate and priority. Mode/A/B are sampled
by fpu_srt_div only under ST_IDLE && start; RC/PC remain live and unchanged.
This recipe is not part of the running FPGA synthesis candidate.
"""
import re

FLAG = 'VEN_SRT_PAYLOAD_SELECT'
BEGIN = "  always_comb begin\n    srt_start = 1'b0;\n    srt_mode  = 2'd0;\n"
END = '\n\n  // All architectural mutation is concentrated in this commit decoder.'
PAYLOAD = '''  // Present operands before the late accept/stack/special-case guard.
  // The engine samples these fields only on start. TOP_TRANS cannot accept
  // an external command, and its divide request has priority over FPTAN done.
  always_comb begin
    srt_mode = 2'd0;
    srt_a = (cmd_aluop == 3'd7) ? alu_b : alu_a;
    srt_b = (cmd_aluop == 3'd7) ? alu_a : alu_b;
    if (top_state == TOP_TRANS) begin
      if (trans_divide_start) begin
        srt_a = trans_divide_a;
        srt_b = trans_divide_b;
      end else begin
        srt_a = trans_primary;
        srt_b = trans_secondary;
      end
    end else if (cmd_op == FX_FSQRT) begin
      srt_mode = 2'd1;
      srt_a = st0_data;
      srt_b = 80'd0;
    end else if ((cmd_op == FX_FPREM) || (cmd_op == FX_FPREM1)) begin
      srt_mode = 2'd2;
      srt_a = st0_data;
      srt_b = sti_data;
    end
  end
'''


def original_block(text):
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise ValueError('missing/ambiguous SRT selector')
    first, last = text.index(BEGIN), text.index(END)
    if last <= first:
        raise ValueError('reversed selector anchors')
    block = text[first:last]
    if 'srt_rc' in block or 'srt_pc' in block:
        raise ValueError('live rounding controls must remain separate')
    return block


def active_block(text):
    old = original_block(text)
    control, count = re.subn(r'^    +srt_(?:mode|a|b)\s*=.*;\n', '', old, flags=re.M)
    if count != 16 or control.count("srt_start = 1'b1;") != 5:
        raise ValueError('unexpected original operand/start assignment shape')
    return control + '\n\n' + PAYLOAD


def transform(text):
    if FLAG in text:
        raise ValueError('already transformed')
    for contract in ('  wire logic accept = cmd_valid & cmd_ready;',
                     '  assign cmd_ready = (top_state == TOP_IDLE);',
                     '       ((top_state == TOP_ALU) && arith_stream_eligible && !arith_stream_hazard));',
                     '      .mode(srt_mode),', '      .a(srt_a),', '      .b(srt_b),'):
        if text.count(contract) != 1:
            raise ValueError('missing/ambiguous producer or consumer: ' + contract)
    old = original_block(text)
    return text.replace(old, '`ifdef ' + FLAG + '\n' + active_block(text) +
                        '\n`else\n' + old + '\n`endif')
