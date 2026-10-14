"""Move the late chain selector after NEXT-line tag reads and comparisons.

Private timing proposal, not promoted RTL. Keep all selected addresses, data
RAM ports, response/permission logic and sequential cache updates unchanged.
Unlike a qualification-based shortcut, this identity needs no valid-request
or no-crossing assumption. FPGA read-port area and timing remain unmeasured.
"""
import hashlib

PARENT = 'a0d3ed6f8fc725975a6833facd4c87adb5ee8f8114d6dd0ea9fbb6b3982d44bf'
OLD = '''`ifdef VEN_L1D_TAG_LUTRAM
  assign hit_n0    = dc_val[set_n][0] && dc_tag[{set_n,1'b0}]==tag_n;
`else
  assign hit_n0    = dc_val[set_n][0] && dc_tag[set_n][0]==tag_n;
`endif
`ifdef VEN_L1D_TAG_LUTRAM
  assign hit_n1    = dc_val[set_n][1] && dc_tag[{set_n,1'b1}]==tag_n;
`else
  assign hit_n1    = dc_val[set_n][1] && dc_tag[set_n][1]==tag_n;
`endif
'''
PARALLEL = '''  // The next-line lookup has the same late-owner hazard as the first.
  // Compute both physical successors before selecting Boolean hit results.
  // Explicit 32-bit additions retain address wrap and set-to-tag carry.
  // addr_n/set_n/tag_n still own data reads, replacement and all updates.
  logic [31:0] tag_current_next_addr, tag_prime_next_addr;
  logic [IDXW-1:0] tag_current_next_set, tag_prime_next_set;
  logic [TAGW-1:0] tag_current_next_value, tag_prime_next_value;
  logic [1:0] tag_current_next_hit, tag_prime_next_hit;
  assign tag_current_next_addr = c_addr + 32'd32;
  assign tag_prime_next_addr = c_next_addr + 32'd32;
  assign tag_current_next_set = tag_current_next_addr[OFFW +: IDXW];
  assign tag_prime_next_set = tag_prime_next_addr[OFFW +: IDXW];
  assign tag_current_next_value = tag_current_next_addr[OFFW+IDXW +: TAGW];
  assign tag_prime_next_value = tag_prime_next_addr[OFFW+IDXW +: TAGW];
  for (genvar next_tag_way = 0; next_tag_way < 2; next_tag_way++) begin : g_parallel_next_tag_lookup
`ifdef VEN_L1D_TAG_LUTRAM
    assign tag_current_next_hit[next_tag_way] = dc_val[tag_current_next_set][next_tag_way] &&
        dc_tag[{tag_current_next_set,1'(next_tag_way)}] == tag_current_next_value;
    assign tag_prime_next_hit[next_tag_way] = dc_val[tag_prime_next_set][next_tag_way] &&
        dc_tag[{tag_prime_next_set,1'(next_tag_way)}] == tag_prime_next_value;
`else
    assign tag_current_next_hit[next_tag_way] = dc_val[tag_current_next_set][next_tag_way] &&
        dc_tag[tag_current_next_set][next_tag_way] == tag_current_next_value;
    assign tag_prime_next_hit[next_tag_way] = dc_val[tag_prime_next_set][next_tag_way] &&
        dc_tag[tag_prime_next_set][next_tag_way] == tag_prime_next_value;
`endif
  end
  assign hit_n0 = mc_lookup_next ? tag_prime_next_hit[0] : tag_current_next_hit[0];
  assign hit_n1 = mc_lookup_next ? tag_prime_next_hit[1] : tag_current_next_hit[1];
'''
NEW = '`ifdef VEN_PIPE_MEM_CHAIN\n'+PARALLEL+'`else\n'+OLD+'`endif\n'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('parallel next-line tag parent drift')
    changed = source.replace(OLD, NEW)
    assert changed.replace(NEW, OLD) == source
    return changed


def lookup_block(source):
    start = source.index('  assign addr_n    = lookup_addr + 32\'d32;')
    end = source.index('  // The line-spill test', start)
    return source[start:end]
