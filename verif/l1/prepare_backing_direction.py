"""Prepare backing direction before request admission, without changing a beat.

Private exact-source experiment. Only inactive m_we may change; every active
request and every request-qualified credit query keeps the original direction.
This is not the rejected address/strobe-mux experiment.
"""
import hashlib
import re

from prepare_backing_payload_mux import PARENT, block

DIRECTION = """  // Direction describes the idle-stage write payload before admission.
  // Only m_req authorizes a beat. A fill remains a read; inactive direction
  // must not feed late c_req/route qualification back into paired credit.
  always_comb begin
    m_we = 1'b0;
    if ((st == L1_IDLE) && !stream_path
`ifndef VEN_P54_LOAD_STORE_PAIR
        && c_we
`endif
       ) m_we = 1'b1;
  end
"""
OLD_WITNESS = """    assert (m_we === backing_before_m_we)
      else $fatal(1,"BACKING-PAIR-PAYLOAD: m_we changed");"""
NEW_WITNESS = """    // No consumer may use direction without an active transaction or
    // c_req-qualified credit query. Both retain the exact old direction.
    if (m_req || c_req)
      assert (m_we === backing_before_m_we)
        else $fatal(1,"BACKING-DIRECTION: consumed direction changed");"""


def changed_block(source):
    old = block(source)
    control, count = re.subn(r'\bm_we\s*=\s*[^;]+;', '', old)
    if count != 4:
        raise ValueError('backing direction assignments drift: '+str(count))
    return ('`ifdef VEN_P54_DUAL_STORE_PAIR\n'+DIRECTION+control+
            '`else\n'+old+'`endif\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('backing direction parent drift/reapplication')
    if source.count(OLD_WITNESS) != 1:
        raise ValueError('backing direction witness drift')
    return source.replace(block(source), changed_block(source), 1).replace(
        OLD_WITNESS, NEW_WITNESS, 1)
