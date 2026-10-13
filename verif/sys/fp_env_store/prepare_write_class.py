"""Classify both x87 environment saves as architectural memory writes.

The shared-core permission sweep already exists. Its owner discriminator is
q_f_mem_write; leaving the decoder flag low turns that sweep into real reads.
No new state, memory transaction, delay, or application-specific behavior.
"""
import hashlib

FILE = 'rtl/core/decode_stages.sv'
PARENT = '1ca62ee810707834a93ad49c1c79e8c2fee7a1bb57cdd000829f9ff22a51ed86'
EDITS = [
    ('3\'d6: begin d_fxop=FX_FNSTENV;  // env store (S_FENV_ST owns the beats)',
     '3\'d6: begin d_fxop=FX_FNSTENV; d_f_mem_write=1\'b1; // probe as a write before masking'),
    ('3\'d6: begin d_fxop=FX_FNSAVE;  // 108-byte state store + FNINIT reinit',
     '3\'d6: begin d_fxop=FX_FNSAVE; d_f_mem_write=1\'b1; // probe as a write before FNINIT'),
]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('environment-write decoder drift/reapplication')
    for old,new in EDITS:
        if source.count(old) != 1:
            raise ValueError('ambiguous environment-write decoder anchor')
        source=source.replace(old,new)
    return source
