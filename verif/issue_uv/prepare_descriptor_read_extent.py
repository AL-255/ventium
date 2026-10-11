"""Narrow the second LGDT/LIDT beat to its two architectural bytes.

Private derivative of the exact-fragment candidate. No opcode, state, clock,
permission, segment-check override, or request-admission change. Both the
translation extent and physical read strobes must agree; changing only one
still permits either a spurious page fault or an excess physical read.
"""
import hashlib

CORE_SHA = 'a6c2c5aabddc268ae2be5b1896d1a9bc6f8780d17eb4e45c62c2f651c48a5cae'
BUS_SHA = 'e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1'
CORE_OLD = "      S_LGDT:  cur_lin_nat = dbase + q_ea + {29'd0, seg_step, 2'b00};"
CORE_NEW = """      S_LGDT: begin
        cur_lin_nat = dbase + q_ea + {29'd0, seg_step, 2'b00};
        // LGDT/LIDT consume six bytes, not two complete dwords. The last
        // two bytes must not translate or segment-check a following page.
        cur_size = seg_step ? 4'd2 : 4'd4;
      end"""
BUS_OLD = "      S_LGDT: begin bd_req =1'b1; end   // (R2-M02: address via cur_lin)"
BUS_NEW = """      S_LGDT: begin
        bd_req = 1'b1;  // address via cur_lin
        // Explicit even for unfragmented reads: zero means a legacy dword.
        bd_wstrb = seg_step ? 4'b0011 : 4'b1111;
      end"""


def transform(core, bus):
    if (hashlib.sha256(core.encode()).hexdigest() != CORE_SHA or
            hashlib.sha256(bus.encode()).hexdigest() != BUS_SHA):
        raise ValueError('descriptor extent predecessor drift')
    result = []
    for source, before, after in ((core, CORE_OLD, CORE_NEW), (bus, BUS_OLD, BUS_NEW)):
        if source.count(before) != 1 or after in source:
            raise ValueError('ambiguous descriptor extent anchor')
        changed = source.replace(before, after)
        if changed.replace(after, before) != source:
            raise ValueError('non-reversible descriptor extent delta')
        result.append(changed)
    return tuple(result)
