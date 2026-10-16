"""Prepare prime widths alongside address payloads, before late validation.

Private exact-parent experiment. The checked descriptor still owns admission;
no stage, request, commit, lookup permission or decoder is added or removed.
"""
import hashlib

FILE = 'rtl/core/core_mem_chain.svh'
PARENT = '3615d9ea4bf93e8c3e08958a1459b111f2bff692822d988d24ec9045f05787ca'


def once(text, old, new):
    if text.count(old) != 1: raise ValueError('prime-width anchor drift: '+old[:80])
    return text.replace(old, new)


def prepare_block(text):
    first = text.index('  always_comb begin\n    mc_prepare_ok =')
    last = text.index('\n  end\n', first)+len('\n  end\n')
    return text[first:last]


def strobe_block(text):
    first = text.index('  assign mem_next_wstrb =')
    return text[first:text.index(';', first)+1]


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT:
        raise ValueError('prime-width predecessor drift/reapplication')
    old = prepare_block(text)
    assert old.count('mc_query_u.w8') == 3 and old.count('mc_query_u.fp_sti[0]') == 2
    new = old.replace('mc_query_u.w8', 'mc_address_payload.w8').replace(
        'mc_query_u.fp_sti[0]', 'mc_address_payload.fp_sti[0]')
    explanation = '''  // The checked nonzero memory descriptor still gates this offer. Its
  // width has the same producer as the already-early address payload; do not
  // serialize descriptor validation before line/segment extent arithmetic.
  // A denied descriptor cannot issue, whatever its unused payload contains.
'''
    result = once(text, old, explanation+new)
    old_strb = strobe_block(text)
    assert old_strb.count('mc_query_u.w8') == 1
    result = once(result, old_strb, old_strb.replace('mc_query_u.w8','mc_address_payload.w8'))
    witness = '''
`ifndef SYNTHESIS
  logic prime_width_old_prepare;
  logic [3:0] prime_width_old_strobe;
'''+old.replace('mc_prepare_ok','prime_width_old_prepare')+old_strb.replace(
        'mem_next_wstrb','prime_width_old_strobe')+'''
  always_ff @(posedge clk) if (rst_n) begin
    assert (mc_prepare_ok === prime_width_old_prepare)
      else $fatal(1,"PRIME-WIDTH: changed preparation eligibility");
    if (mem_next_req)
      assert (mem_next_wstrb === prime_width_old_strobe)
        else $fatal(1,"PRIME-WIDTH: changed offered byte enables");
    if (!agi_prime_select && !ref_prime_select && mc_query_u.len != 0 &&
        (mc_query_u.is_mem || mc_query_u.is_fp))
      assert ({mc_address_payload.w8,mc_address_payload.fp_sti[0]} ===
              {mc_query_u.w8,mc_query_u.fp_sti[0]})
        else $fatal(1,"PRIME-WIDTH: early and checked widths disagree");
  end
`endif
'''
    # This experiment deliberately leaves the request/commit equations and
    # checked descriptor intact, and adds a simulation-only old-result miter.
    return once(result, '  // OFFER is independent of old ACK.', witness+'  // OFFER is independent of old ACK.')
