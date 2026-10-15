"""Remove late pair eligibility from raw branch address payload selection.

Private exact-parent timing experiment. Checked descriptors, offers, commits,
permissions and state are unchanged. Only an unused non-memory payload may
differ. This does not authorize speculative backing reads.
"""
import hashlib
from prepare_mc_address_payload import PAYLOAD, ASSERTION

FILE = 'rtl/core/core_mem_chain.svh'
PARENT = '1f677f3cc7cd43ccea0d05edb564296865e58bd354795810383794b8ab0f077a'
PAYLOAD_NEW = PAYLOAD.replace('if (mc_prime_v_branch) begin', '''// A live V branch cannot itself be a memory/FP descriptor. If it
    // does not pair, its query cannot offer a memory access. Prepare the
    // third-slot address from this early shape; the original checked
    // mc_prime_v_branch still gates descriptor validity and every offer.
    if (v_d.is_branch) begin''')
ASSERTION_NEW = ASSERTION.replace('mc_query_u.len != 0) begin',
    'mc_query_u.len != 0 && (mc_query_u.is_mem || mc_query_u.is_fp)) begin')
ASSERTION_NEW = ASSERTION_NEW.replace('`endif\n`endif\n', '''  // Required decoder invariant, checked independently of whether a hint
  // is accepted. Held and FP-self payloads retain their overriding priority.
  always_ff @(posedge clk) if (rst_n && v_d.is_branch)
    assert (!v_d.is_mem && !v_d.is_fp)
      else $fatal(1, "branch address shape: branch has memory/FP semantics");
`endif
`endif
''')


def once(text, old, new):
    if text.count(old) != 1: raise ValueError('ambiguous branch payload anchor')
    return text.replace(old, new)


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT:
        raise ValueError('branch address predecessor drift/reapplication')
    result = once(once(text, PAYLOAD, PAYLOAD_NEW), ASSERTION, ASSERTION_NEW)
    assert once(once(result, ASSERTION_NEW, ASSERTION), PAYLOAD_NEW, PAYLOAD) == text
    return result
