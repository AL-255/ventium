"""Cut general write ACK from a held read-only V-owner's clear consumer.

Only raw-V/no-dual-prime changes. A live V owner in this profile implies a
held read-only U packet. Clearing an already-zero V bit has no effect. All
capture, reset/fault, translation and terminal-state priorities are retained.
"""
import hashlib

PARENT = 'e2fb72e5e10785cde9a0992da432bf0c7e06b6d386dc13bed230b440d24d48a1'
OLD = '''      end else if ((pipe_mem_active_q && (state == S_PIPE) &&
                   !pipe_mem_abort_now && !xlate_miss && !fe_xlate_pend && mem_ack) ||
'''
NEW = '''      end else if ((pipe_mem_active_q && (state == S_PIPE) &&
                   !pipe_mem_abort_now && !xlate_miss && !fe_xlate_pend &&
`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
                   mem_read_ack) ||
`else
                   mem_ack) ||
`endif
`else
                   mem_ack) ||
`endif
'''
ANCHOR = '''`ifdef VEN_P54_DUAL_LOAD_PAIR
      // Only a fresh U capture can create a V owner.'''
WITNESS = '''`ifdef VEN_P54_DUAL_LOAD_PAIR
`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
`ifndef SYNTHESIS
      // This consumer may differ while V is already zero, never while a live
      // V owner could be retained or cleared. Keep final-fragment suppression.
      if (pipe_mem_v_hit_q && pipe_mem_active_q && state == S_PIPE &&
          !pipe_mem_abort_now && !xlate_miss && !fe_xlate_pend)
        assert (mem_read_ack === mem_ack)
          else $fatal(1, "V-CLEAR-READ-ACK: changed live read-owner completion");
`endif
`endif
`endif
      // Only a fresh U capture can create a V owner.'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('V owner-clear predecessor drift/reapplication')
    for token in (OLD, ANCHOR):
        if source.count(token) != 1:
            raise ValueError('V owner-clear anchor ambiguity')
    return source.replace(OLD, NEW).replace(ANCHOR, WITNESS)
