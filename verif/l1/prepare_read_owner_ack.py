"""Remove speculative lookup from an already owned read's ACK alternatives.

Private derivative of the checked PAIR-INTENT export. Both read consumers use
the same cofactors; original data selection, capture and state remain intact.
"""
import hashlib
from pathlib import Path

import prepare_read_ack_absorption as base

PARENT = 'd3ae3b048f3bb71859e2515fa6a39bcc6ab65db1a92c4d7a5ab9e58f0f01df95'
BASE_SHA = 'bf94e271fc508ccab90224d3c212d60099a8111e658a657d42eea484d8103659'
assert hashlib.sha256(Path(base.__file__).read_bytes()).hexdigest() == BASE_SHA
assignment, ack_block = base.assignment, base.ack_block


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('read-owner source anchor drift: ' + old)
    return text.replace(old, new)


def helpers(source):
    text = base.helpers(source)
    # code_access implies an aligned, cacheable dword, so its CURRENT access
    # cannot cross a line. Both hit-under-fill variants allow this code read
    # only during a data fill. Avoid the selected-next address/extent entirely.
    text = replace(text, 'fill_independent_hit', 'read_ack_code_fill_independent')
    return '''  logic read_ack_code_fill_independent;
`ifdef VEN_L1D_HIT_UNDER_FILL
`ifdef VEN_L1D_CODE_WORD_REUSE
  assign read_ack_code_fill_independent = (st == L1_FILL) &&
      !bypass_q && !code_fill_q;
`else
  assign read_ack_code_fill_independent = 1'b0;
`endif
`else
  assign read_ack_code_fill_independent = 1'b0;
`endif
''' + text


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('read-owner predecessor drift/reapplication')
    original = ack_block(source)
    changed = replace(original, 'window_reuse || shadow_reuse',
                      'read_ack_window_reuse || read_ack_shadow_reuse')
    changed = replace(changed, 'code_word_reuse ||', 'read_ack_code_reuse ||')
    result = replace(source, original, helpers(source) + changed)
    result = replace(result,
        'else                 c_ack = window_reuse || shadow_reuse ||',
        'else                 c_ack = read_ack_window_reuse || read_ack_shadow_reuse ||')
    result = replace(result, '                                 code_word_reuse ||',
                            '                                 read_ack_code_reuse ||')
    # Helpers are also used when the separate FP read-ACK port is disabled.
    # Keep them outside its feature guard, without changing any other guards.
    marker = '''`ifdef VEN_FP_LOAD_EARLY_CMD
  // Read-only response cofactor: no backing-write or paired-store admission.
'''
    result = replace(result, helpers(source), '')
    reference = '''`ifndef SYNTHESIS
  // Preserve the complete old read equation. Comparing only the two new
  // consumers would be circular and would not detect a shared cofactor bug.
  logic c_ack_before_read_owner_cut;
''' + original.replace('c_read_ack', 'c_ack_before_read_owner_cut') + '''  always_ff @(posedge clk) if (rst_n && !c_we) begin
    assert (c_ack === c_ack_before_read_owner_cut)
      else $fatal(1,"READ-OWNER-ACK: changed original read completion");
    if (c_req && mc_lookup_next)
      assert (rd_match)
        else $fatal(1,"READ-OWNER-ACK: lookup lacks the dominating owner");
  end
`endif
'''
    result = replace(result, marker, helpers(source) + reference + '\n' + marker)
    return result
