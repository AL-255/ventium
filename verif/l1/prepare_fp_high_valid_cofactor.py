"""Cofactor wide cached-read validity in an exact, private timing derivative.

No state, data, bus request, ACK, cache capacity or pipeline cycle changes.
The source hash gate protects every response-owner implication used here.
"""
import hashlib
import re

PARENTS = {
    'rtl/mem/ven_l1d.sv': 'c82bf532dfcf80a5c40431fa1f818cb45992745914faf280ef4af58a20477393',
    'rtl/mem/ventium_l1_axi.sv': 'b0bdb4656083d8727264be4f9130dd9fb8b3384cc712cc3a76352af90cf7c95d',
    'rtl/core/core.sv': '94652b5d10c48beed5133a2c318880a511c7ae3f4490363a0e81df2f92fdacb2',
}


def assignment(source, name):
    rows = re.findall(r'  assign '+name+r'\s*= .*?;\n', source, re.S)
    rows = [row for row in rows if "= 1'b0;" not in row]
    if len(rows) != 1:
        raise ValueError('wide-valid assignment drift: '+name)
    return rows[0]


L1 = '''  // A wide response requires a current resident, saved complete line.
  // Its owner/flush/snoop/cacheability guards already imply the read ACK.
  // c_req excludes idle priming; only next_req && rd_match can redirect
  // the read port here. Compare the existing CURRENT tags, not selected
  // next tags, and factor common guards out of the saved-window identities.
  logic fp_high_current_hit, fp_high_window_owned;
`ifdef VEN_PIPE_MEM_CHAIN
  assign fp_high_current_hit = |tag_current_hit;
`else
  assign fp_high_current_hit = hit;
`endif
  assign fp_high_window_owned =
      (rd_full_line_q && (c_addr[31:5] == rd_addr_q[31:5]) &&
       (rd_match
`ifdef VEN_L1D_WINDOW_REUSE
        || (window_valid_q
`ifdef VEN_L1D_CODE_BUFFER
            && !code_access
`endif
           )
`endif
       ))
`ifdef VEN_L1D_TWO_WINDOW_REUSE
      || (shadow_valid_q && (c_addr[31:5] == shadow_line_addr_q)
`ifdef VEN_L1D_CODE_BUFFER
          && !code_access
`endif
         )
`endif
      ;
  assign c_rdata_hi_valid = (L1_LINE == 32) && rst_n && c_req && !c_we &&
      (c_wstrb == 4'hf) && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && !stream_path && !early_armed &&
      (st == L1_IDLE) && fp_high_current_hit && fp_high_window_owned &&
      (c_addr[4:0] <= 5'd24)
`ifdef VEN_PIPE_MEM_CHAIN
      && !(c_next_req && rd_match)
`endif
`ifdef VEN_L1D_COMB_ACK
      && 1'b0 // never attach a registered high half to an asynchronous low half
`endif
      ;
'''


def witness(old, name, clock, reset):
    reference = name+'_before_high_valid_cut'
    return ('`ifndef SYNTHESIS\n  logic '+reference+';\n'+
            old.replace('assign '+name+' =', 'assign '+reference+' =')+
            f'  always_ff @(posedge {clock}) if ({reset})\n'+
            f'    assert ({name} === {reference})\n'+
            f'      else $fatal(1,"FP-HIGH-VALID: {name} changed");\n'+
            '`endif\n')


def replacements(source, path):
    if path == 'rtl/mem/ven_l1d.sv':
        return [('c_rdata_hi_valid', L1, 'clk', 'rst_n')]
    if path == 'rtl/mem/ventium_l1_axi.sv':
        old = assignment(source, 'core_rdata_hi_valid')
        ack = '''`ifdef VEN_FP_LOAD_EARLY_CMD
      l1d_c_read_ack &&
`endif
`ifndef VEN_FP_LOAD_EARLY_CMD
      l1d_c_ack &&
`endif
'''
        if old.count(ack) != 1:
            raise ValueError('wide-valid seam ACK drift')
        return [('core_rdata_hi_valid', old.replace(ack, ''), 'core_clk', 'seam_core_rst_n')]
    old = assignment(source, 'fp_load64_take')
    if old.count('mem_read_ack && bus_rdata_hi_valid') != 1:
        raise ValueError('wide-valid core ACK drift')
    take = old.replace('mem_read_ack && bus_rdata_hi_valid',
                       '!fx_hold_e && bus_rdata_hi_valid')
    take = '''  // The internal L1 high-valid contract includes its read ACK. Keep
  // final-fragment suppression explicit; never use raw high data as a grant.
'''+take
    cmd = assignment(source, 'fp_shared_load_cmd')
    old_complete = '''      ((q_f_mbytes == 4'd4 && f_step == 4'd0) ||
       (q_f_mbytes == 4'd8 && (f_step == 4'd1 || fp_load64_take))) &&'''
    new_complete = '''      ((mem_read_ack && ((q_f_mbytes == 4'd4 && f_step == 4'd0) ||
                          (q_f_mbytes == 4'd8 && f_step == 4'd1))) ||
       fp_load64_take) &&'''
    if cmd.count(old_complete) != 1 or cmd.count('&& mem_read_ack &&') != 1:
        raise ValueError('wide-valid FP command drift')
    cmd = cmd.replace('&& mem_read_ack &&', '&&').replace(old_complete, new_complete)
    return [('fp_load64_take', take, 'clk', 'rst_n'),
            ('fp_shared_load_cmd', cmd, 'clk', 'rst_n')]


def transform(source, path):
    if path not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[path]:
        raise ValueError('wide-valid predecessor drift/reapplication: '+path)
    result = source
    for name, new, clock, reset in replacements(source, path):
        old = assignment(source, name)
        result = result.replace(old, new+witness(old, name, clock, reset))
    if path == 'rtl/core/core.sv':
        anchor = '  logic fp_load64_take;\n`ifdef VEN_FP_LOAD64\n'
        assert result.count(anchor) == 1
        result = result.replace(anchor, anchor+'''`ifndef SYNTHESIS
  // Contract witness for every high-valid response, not just an FP consumer.
  always_ff @(posedge clk) if (rst_n && bus_rdata_hi_valid) begin
    assert (mem_req && !mem_we && bus_ack)
      else $fatal(1,"FP-HIGH-VALID: high response lacks acknowledged read owner");
`ifdef VEN_FP_LOAD_EARLY_CMD
    assert (bus_read_ack)
      else $fatal(1,"FP-HIGH-VALID: high response lacks read ACK");
`endif
  end
`endif
''')
    return result
