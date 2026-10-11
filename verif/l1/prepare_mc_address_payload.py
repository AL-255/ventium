"""Prepare raw-prime address fields in parallel with descriptor validation.

Private experiment: the checked descriptor, offers, commits and all permission
tests remain unchanged. Only the arithmetic payload can differ when unoffered.
"""
import hashlib
import re

PARENT = 'e8cddd9561a4b69c3be59c53b99216bf87851e8732ab5be7e9770f8a372d6129'
OLD = '''  assign mc_query_seg = agi_prime_select ? pipe_mem_seg : ref_prime_select ? d_seg : mc_query_u.mem_ss ? 3'(SG_SS) : 3'(SG_DS);
  assign mc_query_ea = agi_prime_select ? pipe_load_addr : ref_prime_select ? d_ea : (mc_query_u.mem_base_en ? gpr_o[mc_query_u.base] : 32'd0)
      + mc_query_u.mem_disp
      + (mc_query_u.mem_index_en ?
          (gpr_o[mc_query_u.mem_index] << mc_query_u.mem_scale) : 32'd0);
'''
PAYLOAD = '''  // Prepare only the address fields before the descriptor's late byte,
  // code-span and segment validation. mc_query_u remains the checked owner:
  // its nonzero length and memory kind still gate every ordinary prime offer.
  // Held, FP-self and paired-branch sources are mutually exclusive by their
  // existing admission equations; the ordinary unpaired V is the default.
  fpd_t mc_address_payload;
`ifdef VEN_RAW_V_READ_PRIME
  always_comb begin
    mc_address_payload = v_d;
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
    if (mc_prime_v_branch) begin
      mc_address_payload = '0;
      if ({1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} <= 5'd13)
        mc_address_payload = mc_raw_branch_mov(
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len}],
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} + 5'd1],
            ic_front_bytes[{1'b0,pipe_u_eff.len} + {1'b0,pipe_v_eff.len} + 5'd2]);
    end
`endif
    if (mc_fp_self_prime) mc_address_payload = pipe_u_eff;
    if (mc_held_read_prime) mc_address_payload = pipe_mem_v_q;
  end
`else
  assign mc_address_payload = mc_query_u;
`endif
'''
NEW = PAYLOAD + OLD.replace('mc_query_u.', 'mc_address_payload.')
FIELDS = ('mem_ss','mem_base_en','base','mem_disp','mem_index_en','mem_index','mem_scale')
ASSERTION = '''
`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
  always_ff @(posedge clk) if (rst_n && !agi_prime_select && !ref_prime_select &&
                              mc_query_u.len != 0) begin
    assert ({mc_query_u.mem_ss, mc_query_u.mem_base_en, mc_query_u.base,
             mc_query_u.mem_disp, mc_query_u.mem_index_en,
             mc_query_u.mem_index, mc_query_u.mem_scale} ==
            {mc_address_payload.mem_ss, mc_address_payload.mem_base_en, mc_address_payload.base,
             mc_address_payload.mem_disp, mc_address_payload.mem_index_en,
             mc_address_payload.mem_index, mc_address_payload.mem_scale})
      else $fatal(1, "raw prime address payload disagrees with checked descriptor");
  end
`endif
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('raw-prime source drift')
    changed = source.replace(OLD, NEW+ASSERTION)
    if changed.replace(NEW+ASSERTION, OLD) != source:
        raise ValueError('non-reversible address-payload edit')
    return changed


def raw_descriptor(source):
    start = source.index('  function automatic fpd_t mc_descriptor(')
    end = source.index('  endfunction', start)+len('  endfunction')
    return source[start:end]


def assignment(source, name):
    stripped = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    found = re.findall(r'\bassign\s+'+re.escape(name)+r'\s*=\s*([^;]+);', stripped)
    if len(found) != 1:
        raise ValueError('ambiguous assignment: '+name)
    return 'assign '+name+' = '+found[0]+';'
