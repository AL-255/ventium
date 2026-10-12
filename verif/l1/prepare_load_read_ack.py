"""Remove unrelated write completion from the three read-only load FSM arms.

The existing typed ACK retains response ownership, route-denial responses and
final-fragment suppression. Its fallback is the old ACK on other profiles.
No request, state transition, data selection or completion cycle is changed.
"""
import hashlib
import re

PAYLOAD = 'rtl/core/core_load.svh'
PARENT = 'b92dac7ded41285aa042f3924d021916a6ee5ff164b1be4c77c4bae12f24efff'


def witness(state):
    return '''`ifndef SYNTHESIS
          // These sequencers only read (shared-FP stores here only probe).
          assert (!mem_we && (mem_read_ack === mem_ack))
            else $fatal(1, "LOAD-READ-ACK: '''+state+''' owner/completion changed");
          if ($test$plusargs("ven_load_read_ack_witness") && mem_read_ack)
            $display("[LOAD-READ-ACK] '''+state+''' pc=%08x split=%0b cross=%0b far_call=%0b far_jump=%0b",
                     q_pc, xp_pend, xp_cross, q_callf_mem, q_jmpf_mem);
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('read-only load predecessor drift/reapplication')
    if len(re.findall(r'\bmem_ack\b', source)) != 5:
        raise ValueError('load completion consumer count changed')
    result = re.sub(r'\bmem_ack\b', 'mem_read_ack', source)
    for state in ('S_LOAD', 'S_LOAD2', 'S_FLOAD'):
        anchor = '        '+state+': begin\n'
        if result.count(anchor) != 1:
            raise ValueError('load state anchor ambiguity: '+state)
        result = result.replace(anchor, anchor+witness(state))
    return result
