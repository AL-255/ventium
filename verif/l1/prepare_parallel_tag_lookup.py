"""Move the memory-chain select after first-line tag comparisons.

Private timing experiment against the measured write-direction parent. No
request, address, state update, second-line lookup or data read is changed.
The tag read-port cost and mapped timing must be measured before adoption.
"""
import hashlib

PARENT = '279590e09f07f0dfb7b588143678d750371d80356e71517da54c7c7a14139989'
OLD = '''`ifdef VEN_L1D_TAG_LUTRAM
  assign hit0    = dc_val[set_c][0] && dc_tag[{set_c,1'b0}]==tag_c;
`else
  assign hit0    = dc_val[set_c][0] && dc_tag[set_c][0]==tag_c;
`endif
`ifdef VEN_L1D_TAG_LUTRAM
  assign hit1    = dc_val[set_c][1] && dc_tag[{set_c,1'b1}]==tag_c;
`else
  assign hit1    = dc_val[set_c][1] && dc_tag[set_c][1]==tag_c;
`endif
'''
PARALLEL = '''  // Address translation and admission can finish independently of tag
  // comparison. Keep the late memory-chain decision out of the tag read
  // address: select the two Boolean hit results, not the RAM address.
  // The selected set/tag still own every data read and sequential update.
  logic [IDXW-1:0] tag_current_set, tag_prime_set;
  logic [TAGW-1:0] tag_current_value, tag_prime_value;
  logic [1:0] tag_current_hit, tag_prime_hit;
  assign tag_current_set = c_addr[OFFW +: IDXW];
  assign tag_prime_set = c_next_addr[OFFW +: IDXW];
  assign tag_current_value = c_addr[OFFW+IDXW +: TAGW];
  assign tag_prime_value = c_next_addr[OFFW+IDXW +: TAGW];
  for (genvar tag_way = 0; tag_way < 2; tag_way++) begin : g_parallel_tag_lookup
`ifdef VEN_L1D_TAG_LUTRAM
    assign tag_current_hit[tag_way] = dc_val[tag_current_set][tag_way] &&
        dc_tag[{tag_current_set,1'(tag_way)}] == tag_current_value;
    assign tag_prime_hit[tag_way] = dc_val[tag_prime_set][tag_way] &&
        dc_tag[{tag_prime_set,1'(tag_way)}] == tag_prime_value;
`else
    assign tag_current_hit[tag_way] = dc_val[tag_current_set][tag_way] &&
        dc_tag[tag_current_set][tag_way] == tag_current_value;
    assign tag_prime_hit[tag_way] = dc_val[tag_prime_set][tag_way] &&
        dc_tag[tag_prime_set][tag_way] == tag_prime_value;
`endif
  end
  assign hit0 = mc_lookup_next ? tag_prime_hit[0] : tag_current_hit[0];
  assign hit1 = mc_lookup_next ? tag_prime_hit[1] : tag_current_hit[1];
'''
NEW = '`ifdef VEN_PIPE_MEM_CHAIN\n'+PARALLEL+'`else\n'+OLD+'`endif\n'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('parallel tag lookup parent drift')
    changed = source.replace(OLD, NEW)
    if changed.replace(NEW, OLD) != source:
        raise ValueError('non-reversible tag-lookup edit')
    return changed


def lookup_block(source):
    start = source.index('  assign set_c   = lookup_addr[OFFW +: IDXW];')
    end = source.index('  // ---- next-line lookup:', start)
    return source[start:end]
