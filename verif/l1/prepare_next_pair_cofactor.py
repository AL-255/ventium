"""Expose the RAW-profile read/store-pair exclusion before late hint checks.

Only apply after the unmodified-core overlap probe has real pair and all hint
producer coverage. Keep a full request-equivalence assertion in the candidate.
The cache's port-ownership guard remains intact; no permission check moves.
"""
import hashlib

PAYLOAD = 'rtl/core/core_mem_chain.svh'
PARENT = '6e888ab63a31a9100f1e4afd6ee61159111b10518d336ea5fdf0a1aa915ecde4'
ORIGINAL = '  assign mem_next_req = agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer;\n'
COFACTOR = '''  // RAW hints and an actual U-read/V-store packet are mutually exclusive.
  // Expose that fact before the late hint descriptor/translation qualification
  // feeds the cache's paired-store ready path. Shape alone is NOT sufficient:
  // the paid AGI edge may prime U while its decoded V is a store.
  // Retained-uop configurations keep their original arbitration below.
`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_P54_LOAD_STORE_PAIR
  assign mem_next_req = (agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer) &&
                       !(pipe_load_req && pipe_store_pair_shape);
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n)
    assert (mem_next_req === (agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer))
      else $fatal(1,"NEXT-PAIR-COFACTOR: changed resident-read request");
`endif
`else
'''+ORIGINAL+'''`endif
`else
'''+ORIGINAL+'''`endif
'''


def transform(text):
    assert hashlib.sha256(text.encode()).hexdigest() == PARENT
    assert text.count(ORIGINAL) == 1
    changed = text.replace(ORIGINAL, COFACTOR)
    assert changed.replace(COFACTOR, ORIGINAL) == text
    return changed
